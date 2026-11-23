// What the details pane shows about one file: its stat, its type in words, and what the file itself carries (a photo's
// camera and exposure, a song's tags and length, a video's streams, a PDF's pages, the first lines of a text, what an
// archive holds). Folder sizes and checksums run as cancellable tasks with progress.

use crate::util;
use crate::Ctx;
use serde_json::{json, Value};
use std::fs;
use std::io::{BufReader, Read};
use std::os::unix::fs::{MetadataExt, PermissionsExt};
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::Arc;

pub fn info(ctx: &Ctx, path: &Path) -> Result<Value, String> {
    let lmeta = fs::symlink_metadata(path).map_err(|e| crate::list::error_code(&e))?;
    let meta = fs::metadata(path).unwrap_or(lmeta.clone());
    let name = util::name_of(path);
    let dir = meta.is_dir();
    let mime = if dir { "inode/directory".to_string() } else { ctx.mime.of_file(path, &name, meta.len()) };
    let kind = ctx.mime.kind(&mime);
    let mode = meta.permissions().mode() & 0o7777;
    let access = |bit| util::cstr(path).map(|c| unsafe { libc::access(c.as_ptr(), bit) } == 0).unwrap_or(false);
    let mut v = json!({
        "path": path.to_string_lossy(),
        "name": name,
        "parent": path.parent().map(|p| p.to_string_lossy().into_owned()).unwrap_or_default(),
        "dir": dir,
        "size": meta.len(),
        "mime": mime,
        "kind": kind,
        "comment": ctx.mime.comment(&mime),
        "mode": mode,
        "modeText": util::mode_string(mode),
        "owner": util::user_name(meta.uid()),
        "group": util::group_name(meta.gid()),
        "uid": meta.uid(),
        "mtime": util::millis(meta.modified()),
        "atime": util::millis(meta.accessed()),
        "btime": util::millis(meta.created()),
        "readable": access(libc::R_OK),
        "writable": access(libc::W_OK),
        "executable": !dir && access(libc::X_OK),
        "inode": meta.ino(),
        "links": meta.nlink(),
    });
    if lmeta.file_type().is_symlink() {
        v["target"] = json!(fs::read_link(path).map(|t| t.to_string_lossy().into_owned()).unwrap_or_default());
    }
    if dir {
        let (mut files, mut dirs, mut hidden) = (0, 0, 0);
        if let Ok(rd) = fs::read_dir(path) {
            for de in rd.flatten() {
                if de.file_name().to_string_lossy().starts_with('.') {
                    hidden += 1;
                    continue;
                }
                if de.file_type().map(|t| t.is_dir()).unwrap_or(false) { dirs += 1 } else { files += 1 }
            }
        }
        v["files"] = json!(files);
        v["dirs"] = json!(dirs);
        v["hiddenItems"] = json!(hidden);
        if let Some((total, free)) = util::fs_space(path) {
            v["space"] = json!({"total": total, "free": free});
        }
        return Ok(v);
    }
    let top = mime.split('/').next().unwrap_or("");
    match kind {
        "image" => {
            if let Ok(d) = imagesize::size(path) {
                v["width"] = json!(d.width);
                v["height"] = json!(d.height);
            }
            if let Some(e) = exif(path) {
                v["exif"] = e;
            }
        }
        "video" | "audio" => {
            if let Some(m) = probe(path) {
                v["media"] = m;
            }
        }
        "pdf" => {
            if let Some(p) = pdf(path) {
                v["pdf"] = p;
            }
        }
        "archive" => {
            if let Some(a) = archive(path) {
                v["archive"] = a;
            }
        }
        "app" if mime == "application/x-desktop" => {
            v["desktop"] = desktop(path);
        }
        _ => {}
    }
    if kind == "text" || kind == "code" || (top == "text" && kind != "file") {
        v["text"] = text_head(path, 64 * 1024);
    }
    Ok(v)
}

fn exif(path: &Path) -> Option<Value> {
    use exif::{In, Tag};
    let f = fs::File::open(path).ok()?;
    let e = exif::Reader::new().read_from_container(&mut BufReader::new(f)).ok()?;
    let text = |tag| e.get_field(tag, In::PRIMARY).map(|f| f.display_value().with_unit(&e).to_string().trim_matches('"').trim().to_string()).filter(|s| !s.is_empty());
    let mut out = serde_json::Map::new();
    let make = text(Tag::Make).unwrap_or_default();
    let model = text(Tag::Model).unwrap_or_default();
    let camera = if model.to_lowercase().starts_with(&make.to_lowercase()) { model } else { format!("{make} {model}").trim().to_string() };
    if !camera.is_empty() {
        out.insert("camera".into(), json!(camera));
    }
    for (key, tag) in [("lens", Tag::LensModel), ("aperture", Tag::FNumber), ("exposure", Tag::ExposureTime), ("iso", Tag::PhotographicSensitivity),
        ("focal", Tag::FocalLength), ("taken", Tag::DateTimeOriginal), ("software", Tag::Software), ("flash", Tag::Flash)] {
        if let Some(t) = text(tag) {
            out.insert(key.into(), json!(t));
        }
    }
    let coord = |tag, reference| -> Option<f64> {
        let f = e.get_field(tag, In::PRIMARY)?;
        let exif::Value::Rational(ref r) = f.value else { return None };
        if r.len() < 3 {
            return None;
        }
        let deg = r[0].to_f64() + r[1].to_f64() / 60.0 + r[2].to_f64() / 3600.0;
        let neg = text(reference).map(|s| s.starts_with('S') || s.starts_with('W')).unwrap_or(false);
        Some(if neg { -deg } else { deg })
    };
    if let (Some(lat), Some(lon)) = (coord(Tag::GPSLatitude, Tag::GPSLatitudeRef), coord(Tag::GPSLongitude, Tag::GPSLongitudeRef)) {
        out.insert("gps".into(), json!({"lat": lat, "lon": lon}));
    }
    (!out.is_empty()).then(|| Value::Object(out))
}

// The container by the name people know it: ffprobe gives one name to the whole MP4 family and its long names read
// like specifications.
fn container(fmt: &Value, path: &Path) -> String {
    let name = fmt["format_name"].as_str().unwrap_or("");
    let ext = path.extension().and_then(|e| e.to_str()).unwrap_or("").to_ascii_lowercase();
    let brand = fmt["tags"]["major_brand"].as_str().unwrap_or("").trim().to_ascii_lowercase();
    let short = match name.split(',').next().unwrap_or("") {
        "mov" if brand == "qt" || ext == "mov" => "QuickTime",
        "mov" if brand.starts_with("3g") || ext.starts_with("3g") => "3GPP",
        "mov" if ext == "m4a" || brand == "m4a" => "MPEG-4 audio",
        "mov" if brand == "avif" || brand == "heic" || brand == "mif1" => "HEIF",
        "mov" => "MPEG-4",
        "matroska" if ext == "webm" => "WebM",
        "matroska" => "Matroska",
        "mp3" => "MP3",
        "flac" => "FLAC",
        "ogg" => "Ogg",
        "wav" => "WAV",
        "aiff" => "AIFF",
        "avi" => "AVI",
        "mpegts" => "MPEG-TS",
        "mpeg" => "MPEG-PS",
        "asf" => "ASF",
        "flv" => "Flash video",
        "aac" => "AAC",
        "w64" => "Wave64",
        "caf" => "Core Audio",
        "ape" => "Monkey's Audio",
        "wv" => "WavPack",
        "dsf" => "DSD",
        _ => "",
    };
    if short.is_empty() { fmt["format_long_name"].as_str().unwrap_or(name).to_string() } else { short.to_string() }
}

fn probe(path: &Path) -> Option<Value> {
    let raw = util::run_out("ffprobe", &["-v", "quiet", "-print_format", "json", "-show_format", "-show_streams", "-show_chapters", &path.to_string_lossy()], 8000)?;
    let p: Value = serde_json::from_str(&raw).ok()?;
    let fmt = &p["format"];
    let mut out = json!({
        "duration": fmt["duration"].as_str().and_then(|s| s.parse::<f64>().ok()).unwrap_or(0.0),
        "bitrate": fmt["bit_rate"].as_str().and_then(|s| s.parse::<f64>().ok()).unwrap_or(0.0),
        "container": container(fmt, path),
        "chapters": p["chapters"].as_array().map(|c| c.len()).unwrap_or(0),
    });
    let mut tags = serde_json::Map::new();
    let mut collect = |t: &Value| {
        if let Some(obj) = t.as_object() {
            for (k, v) in obj {
                let key = k.to_lowercase();
                if ["title", "artist", "album", "album_artist", "date", "track", "genre", "composer", "comment"].contains(&key.as_str()) && !tags.contains_key(&key) {
                    tags.insert(key, v.clone());
                }
            }
        }
    };
    collect(&fmt["tags"]);
    let mut subtitles = 0;
    let mut audio_tracks = 0;
    for s in p["streams"].as_array().into_iter().flatten() {
        let codec = s["codec_name"].as_str().unwrap_or("").to_string();
        match s["codec_type"].as_str() {
            Some("video") if s["disposition"]["attached_pic"].as_i64() != Some(1) && out.get("video").is_none() => {
                let fps = s["avg_frame_rate"].as_str().and_then(|r| {
                    let (a, b) = r.split_once('/')?;
                    let (a, b) = (a.parse::<f64>().ok()?, b.parse::<f64>().ok()?);
                    (b > 0.0).then(|| a / b)
                }).unwrap_or(0.0);
                let transfer = s["color_transfer"].as_str().unwrap_or("");
                let dovi = s["side_data_list"].as_array().into_iter().flatten()
                    .any(|d| d["side_data_type"].as_str().is_some_and(|t| t.contains("DOVI")));
                let hdr = if dovi { "Dolby Vision" } else { match transfer { "smpte2084" => "HDR10", "arib-std-b67" => "HLG", _ => "" } };
                let depth = s["bits_per_raw_sample"].as_str().and_then(|b| b.parse::<u32>().ok())
                    .or_else(|| s["pix_fmt"].as_str().map(|f| if f.contains("10") { 10 } else if f.contains("12") { 12 } else { 8 })).unwrap_or(8);
                out["video"] = json!({"codec": codec, "profile": s["profile"].as_str().unwrap_or(""), "width": s["width"], "height": s["height"], "fps": fps, "hdr": hdr, "depth": depth});
            }
            Some("video") => out["cover"] = json!(true),
            Some("audio") => {
                audio_tracks += 1;
                if out.get("audio").is_none() {
                    out["audio"] = json!({"codec": codec, "rate": s["sample_rate"].as_str().and_then(|r| r.parse::<u32>().ok()).unwrap_or(0),
                        "channels": s["channels"], "layout": s["channel_layout"].as_str().unwrap_or(""),
                        "depth": s["bits_per_raw_sample"].as_str().and_then(|b| b.parse::<u32>().ok()).unwrap_or(0)});
                    collect(&s["tags"]);
                }
            }
            Some("subtitle") => subtitles += 1,
            _ => {}
        }
    }
    out["audioTracks"] = json!(audio_tracks);
    out["subtitles"] = json!(subtitles);
    out["tags"] = Value::Object(tags);
    Some(out)
}

fn pdf(path: &Path) -> Option<Value> {
    let raw = util::run_out("pdfinfo", &[&path.to_string_lossy()], 5000)?;
    let mut out = serde_json::Map::new();
    for line in raw.lines() {
        let Some((k, v)) = line.split_once(':') else { continue };
        let key = match k.trim() { "Pages" => "pages", "Title" => "title", "Author" => "author", "Producer" => "producer", "Creator" => "creator", "Page size" => "pageSize", "PDF version" => "version", "Encrypted" => "encrypted", _ => continue };
        let val = v.trim();
        if !val.is_empty() {
            out.insert(key.into(), if key == "pages" { json!(val.parse::<u32>().unwrap_or(0)) } else { json!(val) });
        }
    }
    Some(Value::Object(out))
}

/// The first entries an archive lists, and its own size against what it holds.
fn archive(path: &Path) -> Option<Value> {
    use std::io::BufRead;
    use std::process::{Command, Stdio};
    let mut child = Command::new("bsdtar").args(["-tf", &path.to_string_lossy()]).stdin(Stdio::null()).stdout(Stdio::piped()).stderr(Stdio::null()).spawn().ok()?;
    let out = child.stdout.take()?;
    let mut names = Vec::new();
    let mut count = 0usize;
    let mut tops = std::collections::BTreeSet::new();
    for line in std::io::BufReader::new(out).lines().map_while(Result::ok) {
        count += 1;
        if let Some(top) = line.trim_start_matches("./").split('/').next().filter(|t| !t.is_empty()) {
            tops.insert(top.to_string());
        }
        if names.len() < 400 {
            names.push(line);
        }
        if count > 200_000 {
            break;
        }
    }
    let _ = child.kill();
    let _ = child.wait();
    Some(json!({"entries": names, "count": count, "tops": tops.len(), "top": tops.into_iter().take(200).collect::<Vec<_>>()}))
}

fn desktop(path: &Path) -> Value {
    let text = fs::read_to_string(path).unwrap_or_default();
    let mut out = serde_json::Map::new();
    for line in text.lines() {
        if line.starts_with('[') && line != "[Desktop Entry]" {
            break;
        }
        if let Some((k, v)) = line.split_once('=') {
            if ["Name", "Comment", "Icon", "Exec", "Type", "Categories"].contains(&k) {
                out.insert(k.to_lowercase(), json!(v));
            }
        }
    }
    Value::Object(out)
}

pub fn text_head(path: &Path, limit: usize) -> Value {
    let mut buf = Vec::with_capacity(limit);
    let _ = fs::File::open(path).and_then(|f| f.take(limit as u64 + 1).read_to_end(&mut buf));
    let truncated = buf.len() > limit;
    buf.truncate(limit);
    let (text, utf8) = match String::from_utf8(buf) {
        Ok(s) => (s, true),
        Err(e) => {
            let valid = e.utf8_error().valid_up_to();
            let bytes = e.into_bytes();
            // A cut through a multibyte character at the limit is still UTF-8.
            if truncated && bytes.len() - valid < 4 {
                (String::from_utf8_lossy(&bytes[..valid]).into_owned(), true)
            } else {
                (bytes.iter().map(|&b| b as char).collect(), false)
            }
        }
    };
    let lines = text.lines().count();
    json!({"text": text, "truncated": truncated, "utf8": utf8, "lines": lines})
}

/// Walks the paths and reports their size as it grows, until done or cancelled.
pub fn dirsize(ctx: &Ctx, token: &str, paths: Vec<PathBuf>, stop: Arc<AtomicBool>) {
    let (mut size, mut files, mut dirs) = (0u64, 0u64, 0u64);
    let mut seen = std::collections::HashSet::new();
    // The places asked about are not part of what they hold: a folder of one file holds one item.
    let mut stack: Vec<(PathBuf, bool)> = paths.into_iter().map(|p| (p, true)).collect();
    let mut last = std::time::Instant::now();
    while let Some((p, top)) = stack.pop() {
        if stop.load(Ordering::Relaxed) {
            return;
        }
        let Ok(m) = fs::symlink_metadata(&p) else { continue };
        if m.nlink() > 1 && !m.is_dir() && !seen.insert((m.dev(), m.ino())) {
            continue;
        }
        if m.is_dir() {
            dirs += u64::from(!top);
            if let Ok(rd) = fs::read_dir(&p) {
                stack.extend(rd.flatten().map(|d| (d.path(), false)));
            }
        } else {
            files += 1;
            size += m.blocks() * 512;
        }
        if last.elapsed().as_millis() > 150 {
            ctx.out.event("dirsize", json!({"token": token, "size": size, "files": files, "dirs": dirs, "done": false}));
            last = std::time::Instant::now();
        }
    }
    ctx.out.event("dirsize", json!({"token": token, "size": size, "files": files, "dirs": dirs, "done": true}));
}

pub fn checksum(ctx: &Ctx, token: &str, path: &Path, algo: &str, stop: Arc<AtomicBool>) {
    use md5::Md5;
    use sha2::{Digest, Sha256, Sha512};
    let run = || -> Result<String, String> {
        let mut f = fs::File::open(path).map_err(|e| crate::list::error_code(&e))?;
        let total = f.metadata().map(|m| m.len()).unwrap_or(0).max(1);
        let mut buf = vec![0u8; 1 << 20];
        let mut done = 0u64;
        let mut last = std::time::Instant::now();
        macro_rules! digest {
            ($h:expr) => {{
                let mut h = $h;
                loop {
                    if stop.load(Ordering::Relaxed) {
                        return Err("cancelled".into());
                    }
                    let n = f.read(&mut buf).map_err(|e| e.to_string())?;
                    if n == 0 {
                        break;
                    }
                    h.update(&buf[..n]);
                    done += n as u64;
                    if last.elapsed().as_millis() > 150 {
                        ctx.out.event("checksum", json!({"token": token, "progress": done as f64 / total as f64}));
                        last = std::time::Instant::now();
                    }
                }
                format!("{:x}", h.finalize())
            }};
        }
        Ok(match algo {
            "md5" => digest!(Md5::new()),
            "sha512" => digest!(Sha512::new()),
            _ => digest!(Sha256::new()),
        })
    };
    match run() {
        Ok(hex) => ctx.out.event("checksum", json!({"token": token, "progress": 1.0, "value": hex, "algo": algo})),
        Err(e) => ctx.out.event("checksum", json!({"token": token, "error": e})),
    }
}
