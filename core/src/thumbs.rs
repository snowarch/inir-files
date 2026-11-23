// Thumbnails as the freedesktop spec has them: ~/.cache/thumbnails/<size>/<md5 of the URI>.png, tagged with the file's
// URI and mtime, shared with every other file manager. Pictures are made here (a JPEG decoded at the 1/8 step that covers
// the size); everything else goes to the thumbnailers the system has installed (/usr/share/thumbnailers: video, office,
// HEIF, JPEG XL ...), then poppler, ffmpeg or ImageMagick when no thumbnailer claims the type. The newest request goes
// first, so what is on screen fills in before what was scrolled past.

use crate::mime::MimeDb;
use crate::util;
use crate::Ctx;
use md5::{Digest, Md5};
use serde_json::json;
use std::collections::{HashMap, VecDeque};
use std::fs;
use std::io::BufReader;
use std::path::{Path, PathBuf};
use std::sync::{Arc, Condvar, Mutex};

struct Job {
    path: PathBuf,
    size: String,
}

struct Thumbnailer {
    mimes: Vec<String>,
    exec: String,
}

pub struct Thumbs {
    queue: Mutex<VecDeque<Job>>,
    wake: Condvar,
    thumbnailers: Vec<Thumbnailer>,
    can: Mutex<HashMap<String, bool>>,
    pdftoppm: bool,
    ffmpegthumbnailer: bool,
    ffmpeg: bool,
    magick: bool,
}

const NATIVE: &[&str] = &["image/jpeg", "image/png", "image/gif", "image/webp", "image/bmp", "image/x-bmp", "image/tiff", "image/x-icon", "image/vnd.microsoft.icon", "image/x-tga"];
// What Qt draws as it is: a picture already this small is shown from the file itself.
const QT_DRAWS: &[&str] = &["image/jpeg", "image/png", "image/gif", "image/webp", "image/bmp"];

pub fn px(size: &str) -> u32 {
    match size {
        "normal" => 128,
        "x-large" => 512,
        "xx-large" => 1024,
        _ => 256,
    }
}

fn load_thumbnailers() -> Vec<Thumbnailer> {
    let mut seen = std::collections::HashSet::new();
    let mut out = Vec::new();
    for dir in util::data_dirs() {
        let Ok(rd) = fs::read_dir(dir.join("thumbnailers")) else { continue };
        for de in rd.flatten() {
            let name = de.file_name().to_string_lossy().into_owned();
            if !name.ends_with(".thumbnailer") || !seen.insert(name) {
                continue;
            }
            let Ok(text) = fs::read_to_string(de.path()) else { continue };
            let mut exec = String::new();
            let mut mimes = Vec::new();
            let mut try_exec = String::new();
            for line in text.lines() {
                if let Some(v) = line.strip_prefix("Exec=") {
                    exec = v.trim().to_string();
                } else if let Some(v) = line.strip_prefix("MimeType=") {
                    mimes = v.split(';').filter(|m| !m.is_empty()).map(str::to_string).collect();
                } else if let Some(v) = line.strip_prefix("TryExec=") {
                    try_exec = v.trim().to_string();
                }
            }
            let program = if try_exec.is_empty() { split_exec(&exec).into_iter().next().unwrap_or_default() } else { try_exec };
            if !exec.is_empty() && !mimes.is_empty() && util::which(&program).is_some() {
                out.push(Thumbnailer { mimes, exec });
            }
        }
    }
    out
}

/// Splits an Exec line into words, keeping quoted parts together.
pub fn split_exec(exec: &str) -> Vec<String> {
    let mut out = Vec::new();
    let mut cur = String::new();
    let mut quote: Option<char> = None;
    let mut chars = exec.chars().peekable();
    let mut has = false;
    while let Some(c) = chars.next() {
        match (quote, c) {
            (Some(q), c) if c == q => quote = None,
            (Some('"'), '\\') => {
                if let Some(n) = chars.next() {
                    cur.push(n);
                }
            }
            (Some(_), c) => cur.push(c),
            (None, '"') | (None, '\'') => {
                quote = Some(c);
                has = true;
            }
            (None, c) if c.is_whitespace() => {
                if has || !cur.is_empty() {
                    out.push(std::mem::take(&mut cur));
                    has = false;
                }
            }
            (None, '\\') => {
                if let Some(n) = chars.next() {
                    cur.push(n);
                }
            }
            (None, c) => cur.push(c),
        }
    }
    if has || !cur.is_empty() {
        out.push(cur);
    }
    out
}

impl Thumbs {
    pub fn new() -> Self {
        Thumbs {
            queue: Mutex::new(VecDeque::new()),
            wake: Condvar::new(),
            thumbnailers: load_thumbnailers(),
            can: Mutex::new(HashMap::new()),
            pdftoppm: util::which("pdftoppm").is_some(),
            ffmpegthumbnailer: util::which("ffmpegthumbnailer").is_some(),
            ffmpeg: util::which("ffmpeg").is_some(),
            magick: util::which("magick").is_some(),
        }
    }

    fn thumbnailer_for(&self, db: &MimeDb, mime: &str) -> Option<&Thumbnailer> {
        for m in db.lineage(mime) {
            if let Some(t) = self.thumbnailers.iter().find(|t| t.mimes.iter().any(|x| x == &m)) {
                return Some(t);
            }
        }
        None
    }

    /// Whether a picture of this type can be made at all.
    pub fn can(&self, db: &MimeDb, mime: &str) -> bool {
        if let Some(&c) = self.can.lock().unwrap().get(mime) {
            return c;
        }
        let top = mime.split('/').next().unwrap_or("");
        let c = NATIVE.contains(&mime)
            || mime == "image/svg+xml"
            || self.thumbnailer_for(db, mime).is_some()
            || (mime == "application/pdf" && self.pdftoppm)
            || (top == "video" && (self.ffmpegthumbnailer || self.ffmpeg))
            || (top == "audio" && self.ffmpeg)
            || (top == "image" && self.magick);
        self.can.lock().unwrap().insert(mime.to_string(), c);
        c
    }

    pub fn request(&self, path: PathBuf, size: String) {
        let mut q = self.queue.lock().unwrap();
        if let Some(at) = q.iter().position(|j| j.path == path && j.size == size) {
            q.remove(at);
        }
        q.push_back(Job { path, size });
        while q.len() > 4000 {
            q.pop_front();
        }
        drop(q);
        self.wake.notify_one();
    }

    pub fn clear(&self) {
        self.queue.lock().unwrap().clear();
    }
}

pub fn start(ctx: Arc<Ctx>) {
    let n = std::thread::available_parallelism().map(|n| n.get()).unwrap_or(4).clamp(2, 6) - 1;
    for _ in 0..n.max(2) {
        let ctx = ctx.clone();
        std::thread::spawn(move || loop {
            let job = {
                let mut q = ctx.thumbs.queue.lock().unwrap();
                loop {
                    if let Some(j) = q.pop_back() {
                        break j;
                    }
                    q = ctx.thumbs.wake.wait(q).unwrap();
                }
            };
            let file = make(&ctx, &job.path, &job.size).unwrap_or_default();
            ctx.out.event("thumb", json!({"path": job.path.to_string_lossy(), "size": job.size, "file": file}));
        });
    }
}

fn hash(uri: &str) -> String {
    format!("{:x}", Md5::digest(uri.as_bytes()))
}

pub fn cache_path(path: &Path, size: &str) -> PathBuf {
    util::cache_home().join("thumbnails").join(size).join(format!("{}.png", hash(&util::uri(path))))
}

fn fail_path(path: &Path) -> PathBuf {
    util::cache_home().join("thumbnails/fail/inir-files").join(format!("{}.png", hash(&util::uri(path))))
}

/// True when the PNG at thumb was made from this very version of the file.
fn fresh(thumb: &Path, mtime: i64) -> bool {
    let Ok(f) = fs::File::open(thumb) else { return false };
    let mut dec = png::Decoder::new(BufReader::new(f));
    dec.set_ignore_text_chunk(false);
    let Ok(reader) = dec.read_info() else { return false };
    let info = reader.info();
    let found = info.uncompressed_latin1_text.iter().find(|t| t.keyword == "Thumb::MTime").map(|t| t.text.clone())
        .or_else(|| info.utf8_text.iter().find(|t| t.keyword == "Thumb::MTime").and_then(|t| t.get_text().ok()));
    found.and_then(|t| t.trim().parse::<i64>().ok()) == Some(mtime)
}

fn save_tagged(img: &image::DynamicImage, out: &Path, src: &Path, mtime: i64) -> bool {
    let rgba = img.to_rgba8();
    // Two asks for one thumbnail can meet: each writes its own file, the last rename wins whole.
    let tmp = out.with_extension(format!("{}-{}.tmp", std::process::id(), rand_suffix()));
    let write = || -> Result<(), Box<dyn std::error::Error>> {
        let file = fs::File::create(&tmp)?;
        let mut enc = png::Encoder::new(std::io::BufWriter::new(file), rgba.width(), rgba.height());
        enc.set_color(png::ColorType::Rgba);
        enc.set_depth(png::BitDepth::Eight);
        enc.set_compression(png::Compression::Fast);
        enc.add_text_chunk("Thumb::URI".into(), util::uri(src))?;
        enc.add_text_chunk("Thumb::MTime".into(), mtime.to_string())?;
        enc.add_text_chunk("Software".into(), "iNiR Files".into())?;
        enc.write_header()?.write_image_data(rgba.as_raw())?;
        Ok(())
    };
    if let Some(dir) = out.parent() {
        let _ = fs::create_dir_all(dir);
    }
    if write().is_ok() && fs::rename(&tmp, out).is_ok() {
        return true;
    }
    let _ = fs::remove_file(&tmp);
    false
}

fn orientation(path: &Path) -> u32 {
    let Ok(f) = fs::File::open(path) else { return 1 };
    let Ok(exif) = exif::Reader::new().read_from_container(&mut BufReader::new(f)) else { return 1 };
    exif.get_field(exif::Tag::Orientation, exif::In::PRIMARY).and_then(|f| f.value.get_uint(0)).unwrap_or(1)
}

fn orient(img: image::DynamicImage, o: u32) -> image::DynamicImage {
    match o {
        2 => img.fliph(),
        3 => img.rotate180(),
        4 => img.flipv(),
        5 => img.rotate90().fliph(),
        6 => img.rotate90(),
        7 => img.rotate270().fliph(),
        8 => img.rotate270(),
        _ => img,
    }
}

fn open_jpeg_scaled(path: &Path, side: u32) -> Option<image::DynamicImage> {
    let mut dec = jpeg_decoder::Decoder::new(BufReader::new(fs::File::open(path).ok()?));
    let s = side.min(u16::MAX as u32) as u16;
    dec.scale(s, s).ok()?;
    let pixels = dec.decode().ok()?;
    let info = dec.info()?;
    let (w, h) = (info.width as u32, info.height as u32);
    match info.pixel_format {
        jpeg_decoder::PixelFormat::RGB24 => image::RgbImage::from_raw(w, h, pixels).map(image::DynamicImage::ImageRgb8),
        jpeg_decoder::PixelFormat::L8 => image::GrayImage::from_raw(w, h, pixels).map(image::DynamicImage::ImageLuma8),
        _ => None,
    }
}

fn fit(img: image::DynamicImage, side: u32) -> image::DynamicImage {
    if img.width() <= side && img.height() <= side {
        img
    } else {
        img.resize(side, side, image::imageops::FilterType::Triangle)
    }
}

fn run_timeout(argv: &[String], ms: u64) -> bool {
    use std::process::{Command, Stdio};
    let Some((prog, args)) = argv.split_first() else { return false };
    let Ok(mut child) = Command::new(prog).args(args).stdin(Stdio::null()).stdout(Stdio::null()).stderr(Stdio::null()).spawn() else { return false };
    let start = std::time::Instant::now();
    loop {
        match child.try_wait() {
            Ok(Some(st)) => return st.success(),
            Ok(None) if start.elapsed().as_millis() as u64 > ms => {
                let _ = child.kill();
                let _ = child.wait();
                return false;
            }
            Ok(None) => std::thread::sleep(std::time::Duration::from_millis(10)),
            Err(_) => return false,
        }
    }
}

/// The external tool's picture, made into a tagged thumbnail.
fn external(argv: Vec<String>, tmp: &Path, out: &Path, src: &Path, mtime: i64, side: u32) -> bool {
    let ok = run_timeout(&argv, 20000) && tmp.exists();
    let done = ok && image::ImageReader::open(tmp).ok().and_then(|r| r.with_guessed_format().ok()).and_then(|r| r.decode().ok())
        .map(|img| save_tagged(&fit(img, side), out, src, mtime)).unwrap_or(false);
    let _ = fs::remove_file(tmp);
    done
}

/// The path of a picture for path at size: a cached thumbnail, a new one, or the file itself when it is small enough
/// to be drawn as it is. None when nothing could be made.
pub fn make(ctx: &Ctx, path: &Path, size: &str) -> Option<String> {
    let meta = fs::metadata(path).ok()?;
    if !meta.is_file() {
        return None;
    }
    let mtime = util::secs(meta.modified());
    let name = util::name_of(path);
    let mime = ctx.mime.of_file(path, &name, meta.len());
    if mime == "image/svg+xml" {
        return Some(path.to_string_lossy().into_owned());
    }
    let side = px(size);
    // A cached one of this size or larger.
    for s in ["normal", "large", "x-large", "xx-large"] {
        if px(s) < side {
            continue;
        }
        let p = cache_path(path, s);
        if fresh(&p, mtime) {
            return Some(p.to_string_lossy().into_owned());
        }
    }
    let fail = fail_path(path);
    if fresh(&fail, mtime) {
        return None;
    }
    let out = cache_path(path, size);
    if let Some(dir) = out.parent() {
        let _ = fs::create_dir_all(dir);
    }
    // Inside the cache: a thumbnail's own tmp file never lands in a folder the person sees.
    let tmp = out.with_extension(format!("src{}-{}.png", std::process::id(), rand_suffix()));
    let src = path.to_string_lossy().into_owned();
    let top = mime.split('/').next().unwrap_or("");

    let made = if NATIVE.contains(&mime.as_str()) {
        let dims = imagesize::size(path).ok();
        if QT_DRAWS.contains(&mime.as_str()) && dims.map(|d| d.width as u32 <= side && d.height as u32 <= side).unwrap_or(false) {
            return Some(src);
        }
        let img = if mime == "image/jpeg" { open_jpeg_scaled(path, side) } else { None }
            .or_else(|| image::ImageReader::open(path).ok()?.with_guessed_format().ok()?.decode().ok());
        match img {
            Some(img) => {
                let o = if mime == "image/jpeg" || mime == "image/tiff" || mime == "image/webp" { orientation(path) } else { 1 };
                save_tagged(&orient(fit(img, side), o), &out, path, mtime)
            }
            None => false,
        }
    } else if let Some(t) = ctx.thumbs.thumbnailer_for(&ctx.mime, &mime) {
        let argv: Vec<String> = split_exec(&t.exec).into_iter().map(|w| {
            w.replace("%%", "\u{0}").replace("%i", &src).replace("%u", &util::uri(path)).replace("%o", &tmp.to_string_lossy())
                .replace("%s", &side.to_string()).replace('\u{0}', "%")
        }).collect();
        external(argv, &tmp, &out, path, mtime, side)
    } else if mime == "application/pdf" && ctx.thumbs.pdftoppm {
        let prefix = tmp.with_extension("");
        let argv = vec!["pdftoppm".into(), "-png".into(), "-f".into(), "1".into(), "-l".into(), "1".into(), "-singlefile".into(),
            "-scale-to".into(), side.to_string(), src.clone(), prefix.to_string_lossy().into_owned()];
        // pdftoppm adds .png to the prefix, which gives tmp back.
        external(argv, &tmp, &out, path, mtime, side)
    } else if top == "video" && ctx.thumbs.ffmpegthumbnailer {
        let argv = vec!["ffmpegthumbnailer".into(), "-i".into(), src.clone(), "-o".into(), tmp.to_string_lossy().into_owned(), "-s".into(), side.to_string(), "-c".into(), "png".into(), "-t".into(), "10%".into()];
        external(argv, &tmp, &out, path, mtime, side)
    } else if (top == "video" || top == "audio") && ctx.thumbs.ffmpeg {
        let scale = format!("scale={side}:{side}:force_original_aspect_ratio=decrease");
        let mut argv: Vec<String> = vec!["ffmpeg".into(), "-v".into(), "error".into(), "-y".into()];
        if top == "video" {
            argv.extend(["-ss".into(), "3".into()]);
        }
        argv.extend(["-i".into(), src.clone(), "-an".into(), "-frames:v".into(), "1".into(), "-vf".into(), scale, tmp.to_string_lossy().into_owned()]);
        external(argv, &tmp, &out, path, mtime, side)
    } else if top == "image" && ctx.thumbs.magick {
        let argv = vec!["magick".into(), format!("{src}[0]"), "-auto-orient".into(), "-thumbnail".into(), format!("{side}x{side}"), tmp.to_string_lossy().into_owned()];
        external(argv, &tmp, &out, path, mtime, side)
    } else {
        false
    };
    if made {
        return Some(out.to_string_lossy().into_owned());
    }
    // Remember the failure for this version of the file, so it is not tried on every visit.
    save_tagged(&image::DynamicImage::new_rgba8(1, 1), &fail, path, mtime);
    None
}

/// A page of a PDF, or a picture the interface cannot read itself (AVIF, HEIC, JPEG XL, RAW, PSD ...), drawn as a PNG
/// about side pixels on its long edge for a large view. Cached by file, version, page and size; sizes go in steps of
/// 256 so a window resized a little reuses what is drawn.
pub fn render(ctx: &Ctx, path: &Path, page: u32, side: u32) -> Result<serde_json::Value, String> {
    let meta = fs::metadata(path).map_err(|e| e.to_string())?;
    let mtime = util::secs(meta.modified());
    let mime = ctx.mime.of_file(path, &util::name_of(path), meta.len());
    let side = side.clamp(64, 4096).div_ceil(256) * 256;
    let out = util::cache_home().join("inir-files/render").join(format!("{}-{}-{}.png", hash(&util::uri(path)), page, side));
    if fresh(&out, mtime) {
        return Ok(json!({"file": out.to_string_lossy()}));
    }
    if let Some(dir) = out.parent() {
        let _ = fs::create_dir_all(dir);
    }
    let src = path.to_string_lossy().into_owned();
    let tmp = out.with_extension(format!("src{}-{}.png", std::process::id(), rand_suffix()));
    let made = if mime == "application/pdf" {
        if !ctx.thumbs.pdftoppm {
            return Err("nopoppler".into());
        }
        let n = (page + 1).to_string();
        let prefix = tmp.with_extension("");
        let argv = vec!["pdftoppm".into(), "-png".into(), "-f".into(), n.clone(), "-l".into(), n, "-singlefile".into(),
            "-scale-to".into(), side.to_string(), src, prefix.to_string_lossy().into_owned()];
        external(argv, &tmp, &out, path, mtime, side)
    } else if let Some(img) = image::ImageReader::open(path).ok().and_then(|r| r.with_guessed_format().ok()).and_then(|r| r.decode().ok()) {
        save_tagged(&fit(img, side), &out, path, mtime)
    } else if ctx.thumbs.magick {
        let argv = vec!["magick".into(), format!("{src}[{page}]"), "-auto-orient".into(), "-resize".into(), format!("{side}x{side}>"),
            tmp.to_string_lossy().into_owned()];
        external(argv, &tmp, &out, path, mtime, side)
    } else {
        false
    };
    if made { Ok(json!({"file": out.to_string_lossy()})) } else { Err("render".into()) }
}

fn rand_suffix() -> usize {
    use std::sync::atomic::{AtomicUsize, Ordering};
    static N: AtomicUsize = AtomicUsize::new(0);
    N.fetch_add(1, Ordering::Relaxed)
}

#[cfg(test)]
mod tests {
    #[test]
    fn exec_words() {
        assert_eq!(super::split_exec("a -s %s \"%i\" 'x y'"), ["a", "-s", "%s", "%i", "x y"]);
    }
}
