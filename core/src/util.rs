// Small things every part of the core shares: paths of the XDG layout, file URIs as GLib writes them, the natural
// order people expect ("photo 2" before "photo 10") and free names ("name (2).ext").

use percent_encoding::{percent_decode_str, utf8_percent_encode, AsciiSet, CONTROLS};
use std::cmp::Ordering;
use std::ffi::CString;
use std::os::unix::ffi::OsStrExt;
use std::path::{Path, PathBuf};
use std::time::UNIX_EPOCH;

pub fn env_path(key: &str) -> Option<PathBuf> {
    std::env::var_os(key).filter(|v| !v.is_empty()).map(PathBuf::from)
}

pub fn home() -> PathBuf {
    env_path("HOME").unwrap_or_else(|| PathBuf::from("/"))
}

pub fn config_home() -> PathBuf {
    env_path("XDG_CONFIG_HOME").unwrap_or_else(|| home().join(".config"))
}

pub fn data_home() -> PathBuf {
    env_path("XDG_DATA_HOME").unwrap_or_else(|| home().join(".local/share"))
}

pub fn cache_home() -> PathBuf {
    env_path("XDG_CACHE_HOME").unwrap_or_else(|| home().join(".cache"))
}

pub fn state_home() -> PathBuf {
    env_path("XDG_STATE_HOME").unwrap_or_else(|| home().join(".local/state"))
}

/// Where gvfsd-fuse shows connected servers: the gvfs folder of the session's runtime folder.
pub fn gvfs_dir() -> PathBuf {
    env_path("XDG_RUNTIME_DIR").unwrap_or_else(|| PathBuf::from(format!("/run/user/{}", unsafe { libc::getuid() }))).join("gvfs")
}

/// XDG_DATA_HOME first, then every XDG_DATA_DIRS entry.
pub fn data_dirs() -> Vec<PathBuf> {
    let mut dirs = vec![data_home()];
    let sys = std::env::var("XDG_DATA_DIRS").ok().filter(|s| !s.is_empty()).unwrap_or_else(|| "/usr/local/share:/usr/share".into());
    for d in sys.split(':').filter(|d| !d.is_empty()) {
        let p = PathBuf::from(d);
        if !dirs.contains(&p) {
            dirs.push(p);
        }
    }
    dirs
}

pub fn config_dirs() -> Vec<PathBuf> {
    let mut dirs = vec![config_home()];
    let sys = std::env::var("XDG_CONFIG_DIRS").ok().filter(|s| !s.is_empty()).unwrap_or_else(|| "/etc/xdg".into());
    for d in sys.split(':').filter(|d| !d.is_empty()) {
        dirs.push(PathBuf::from(d));
    }
    dirs
}

// What GLib leaves unescaped in a file URI's path (g_escape_uri_string, UNSAFE_PATH): thumbnails are named by the MD5 of
// that URI, so the cache is shared with every other file manager only when it is written byte for byte the same.
const URI_PATH: &AsciiSet = &CONTROLS
    .add(b' ').add(b'"').add(b'#').add(b'%').add(b';').add(b'<').add(b'>').add(b'?')
    .add(b'[').add(b'\\').add(b']').add(b'^').add(0x60).add(b'{').add(b'|').add(b'}').add(0x7f);

pub fn uri(path: &Path) -> String {
    let raw = path.as_os_str().as_bytes();
    // Non-UTF-8 names are escaped byte by byte, as GLib does.
    let mut out = String::from("file://");
    match std::str::from_utf8(raw) {
        Ok(s) => out.extend(utf8_percent_encode(s, URI_PATH)),
        Err(_) => out.extend(percent_encoding::percent_encode(raw, URI_PATH)),
    }
    out
}

pub fn path_from_uri(uri: &str) -> Option<PathBuf> {
    let rest = uri.strip_prefix("file://")?;
    // file://host/path: only the local host.
    let rest = if rest.starts_with('/') { rest } else { &rest[rest.find('/')?..] };
    let bytes: Vec<u8> = percent_decode_str(rest).collect();
    Some(PathBuf::from(std::ffi::OsStr::from_bytes(&bytes)))
}

pub fn secs(t: std::io::Result<std::time::SystemTime>) -> i64 {
    t.ok().and_then(|t| t.duration_since(UNIX_EPOCH).ok()).map(|d| d.as_secs() as i64).unwrap_or(0)
}

pub fn millis(t: std::io::Result<std::time::SystemTime>) -> f64 {
    t.ok().and_then(|t| t.duration_since(UNIX_EPOCH).ok()).map(|d| d.as_millis() as f64).unwrap_or(0.0)
}

pub fn name_of(path: &Path) -> String {
    path.file_name().map(|n| n.to_string_lossy().into_owned()).unwrap_or_else(|| path.to_string_lossy().into_owned())
}

/// Splits "archive.tar.gz" into ("archive", ".tar.gz") and "photo.jpg" into ("photo", ".jpg"); a dotfile keeps its name.
pub fn split_ext(name: &str) -> (&str, &str) {
    let lower = name.to_ascii_lowercase();
    for double in [".tar.gz", ".tar.bz2", ".tar.xz", ".tar.zst", ".tar.lz", ".tar.lzma", ".tar.z"] {
        if lower.ends_with(double) && name.len() > double.len() {
            let at = name.len() - double.len();
            return (&name[..at], &name[at..]);
        }
    }
    match name.rfind('.') {
        Some(at) if at > 0 => (&name[..at], &name[at..]),
        _ => (name, ""),
    }
}

/// A name in dir nobody uses yet: "name.ext", then "name (2).ext", "name (3).ext" ...
pub fn free_name(dir: &Path, name: &str) -> PathBuf {
    let first = dir.join(name);
    if first.symlink_metadata().is_err() {
        return first;
    }
    let (stem, ext) = split_ext(name);
    // "report (2)" continues at 3, never "report (2) (2)".
    let (base, mut n) = match stem.rfind(" (") {
        Some(at) if stem.ends_with(')') => match stem[at + 2..stem.len() - 1].parse::<u32>() {
            Ok(k) => (&stem[..at], k + 1),
            Err(_) => (stem, 2),
        },
        _ => (stem, 2),
    };
    loop {
        let candidate = dir.join(format!("{base} ({n}){ext}"));
        if candidate.symlink_metadata().is_err() {
            return candidate;
        }
        n += 1;
    }
}

/// The order a person expects: case and accents set aside, digit runs compared as numbers.
pub fn natural_cmp(a: &str, b: &str) -> Ordering {
    let (fa, fb) = (fold(a), fold(b));
    let (mut ia, mut ib) = (fa.chars().peekable(), fb.chars().peekable());
    loop {
        match (ia.peek().copied(), ib.peek().copied()) {
            (None, None) => return a.cmp(b),
            (None, Some(_)) => return Ordering::Less,
            (Some(_), None) => return Ordering::Greater,
            (Some(ca), Some(cb)) if ca.is_ascii_digit() && cb.is_ascii_digit() => {
                let mut na = String::new();
                while let Some(c) = ia.peek().copied().filter(|c| c.is_ascii_digit()) {
                    na.push(c);
                    ia.next();
                }
                let mut nb = String::new();
                while let Some(c) = ib.peek().copied().filter(|c| c.is_ascii_digit()) {
                    nb.push(c);
                    ib.next();
                }
                let (ta, tb) = (na.trim_start_matches('0'), nb.trim_start_matches('0'));
                let ord = ta.len().cmp(&tb.len()).then_with(|| ta.cmp(tb)).then_with(|| nb.len().cmp(&na.len()));
                if ord != Ordering::Equal {
                    return ord;
                }
            }
            (Some(ca), Some(cb)) => {
                if ca != cb {
                    return ca.cmp(&cb);
                }
                ia.next();
                ib.next();
            }
        }
    }
}

/// Lower case without the common Latin accents, for sorting and matching ("Árbol" sits with "arbol").
pub fn fold(s: &str) -> String {
    s.chars()
        .flat_map(|c| c.to_lowercase())
        .map(|c| match c {
            'á' | 'à' | 'ä' | 'â' | 'ã' | 'å' => 'a',
            'é' | 'è' | 'ë' | 'ê' => 'e',
            'í' | 'ì' | 'ï' | 'î' => 'i',
            'ó' | 'ò' | 'ö' | 'ô' | 'õ' => 'o',
            'ú' | 'ù' | 'ü' | 'û' => 'u',
            'ñ' => 'n',
            'ç' => 'c',
            _ => c,
        })
        .collect()
}

pub fn cstr(path: &Path) -> Option<CString> {
    CString::new(path.as_os_str().as_bytes()).ok()
}

/// (total, free for the user) bytes of the filesystem holding path.
pub fn fs_space(path: &Path) -> Option<(u64, u64)> {
    let c = cstr(path)?;
    let mut st: libc::statvfs = unsafe { std::mem::zeroed() };
    if unsafe { libc::statvfs(c.as_ptr(), &mut st) } != 0 {
        return None;
    }
    let frsize = if st.f_frsize > 0 { st.f_frsize } else { st.f_bsize } as u64;
    Some((st.f_blocks as u64 * frsize, st.f_bavail as u64 * frsize))
}

/// True on network and FUSE filesystems, where reading every folder's size or every picture costs a round trip.
pub fn is_remote(path: &Path) -> bool {
    let Some(c) = cstr(path) else { return false };
    let mut st: libc::statfs = unsafe { std::mem::zeroed() };
    if unsafe { libc::statfs(c.as_ptr(), &mut st) } != 0 {
        return false;
    }
    let kind = st.f_type as u32;
    matches!(kind, 0x6969 | 0x517B | 0xFF534D42 | 0xFE534D42 | 0x65735546 | 0x564c)
}

pub fn can_write(path: &Path) -> bool {
    cstr(path).map(|c| unsafe { libc::access(c.as_ptr(), libc::W_OK) } == 0).unwrap_or(false)
}

pub fn user_name(uid: u32) -> String {
    let mut buf = vec![0 as libc::c_char; 4096];
    let mut pwd: libc::passwd = unsafe { std::mem::zeroed() };
    let mut out: *mut libc::passwd = std::ptr::null_mut();
    let rc = unsafe { libc::getpwuid_r(uid, &mut pwd, buf.as_mut_ptr(), buf.len(), &mut out) };
    if rc == 0 && !out.is_null() {
        unsafe { std::ffi::CStr::from_ptr(pwd.pw_name) }.to_string_lossy().into_owned()
    } else {
        uid.to_string()
    }
}

pub fn group_name(gid: u32) -> String {
    let mut buf = vec![0 as libc::c_char; 4096];
    let mut grp: libc::group = unsafe { std::mem::zeroed() };
    let mut out: *mut libc::group = std::ptr::null_mut();
    let rc = unsafe { libc::getgrgid_r(gid, &mut grp, buf.as_mut_ptr(), buf.len(), &mut out) };
    if rc == 0 && !out.is_null() {
        unsafe { std::ffi::CStr::from_ptr(grp.gr_name) }.to_string_lossy().into_owned()
    } else {
        gid.to_string()
    }
}

pub fn mode_string(mode: u32) -> String {
    let mut s = String::with_capacity(9);
    for (bit, c) in [(0o400, 'r'), (0o200, 'w'), (0o100, 'x'), (0o040, 'r'), (0o020, 'w'), (0o010, 'x'), (0o004, 'r'), (0o002, 'w'), (0o001, 'x')] {
        s.push(if mode & bit != 0 { c } else { '-' });
    }
    s
}

/// Runs a program and gives its stdout when it exits with 0 within the time.
pub fn run_out(program: &str, args: &[&str], timeout_ms: u64) -> Option<String> {
    use std::process::{Command, Stdio};
    let mut child = Command::new(program).args(args).stdin(Stdio::null()).stdout(Stdio::piped()).stderr(Stdio::null()).spawn().ok()?;
    let mut stdout = child.stdout.take()?;
    let reader = std::thread::spawn(move || {
        let mut s = Vec::new();
        let _ = std::io::Read::read_to_end(&mut stdout, &mut s);
        s
    });
    let start = std::time::Instant::now();
    loop {
        match child.try_wait() {
            Ok(Some(status)) => {
                let bytes = reader.join().ok()?;
                return status.success().then(|| String::from_utf8_lossy(&bytes).into_owned());
            }
            Ok(None) if start.elapsed().as_millis() as u64 > timeout_ms => {
                let _ = child.kill();
                let _ = child.wait();
                return None;
            }
            Ok(None) => std::thread::sleep(std::time::Duration::from_millis(5)),
            Err(_) => return None,
        }
    }
}

/// Runs a program and gives (success, stderr) once it exits.
pub fn run_status(program: &str, args: &[&str]) -> (bool, String) {
    use std::process::{Command, Stdio};
    match Command::new(program).args(args).stdin(Stdio::null()).stdout(Stdio::null()).stderr(Stdio::piped()).output() {
        Ok(out) => (out.status.success(), String::from_utf8_lossy(&out.stderr).trim().to_string()),
        Err(e) => (false, e.to_string()),
    }
}

pub fn which(program: &str) -> Option<PathBuf> {
    if program.contains('/') {
        return Some(PathBuf::from(program)).filter(|p| p.is_file());
    }
    let path = std::env::var_os("PATH")?;
    std::env::split_paths(&path).map(|d| d.join(program)).find(|p| {
        p.is_file() && cstr(p).map(|c| unsafe { libc::access(c.as_ptr(), libc::X_OK) } == 0).unwrap_or(false)
    })
}

/// A program started on its own session, its output dropped; a thread reaps it so no zombie stays behind.
pub fn spawn_detached(argv: &[String], cwd: Option<&Path>) -> std::io::Result<()> {
    use std::os::unix::process::CommandExt;
    use std::process::{Command, Stdio};
    let (prog, args) = argv.split_first().ok_or_else(|| std::io::Error::other("empty command"))?;
    let mut cmd = Command::new(prog);
    cmd.args(args).stdin(Stdio::null()).stdout(Stdio::null()).stderr(Stdio::null());
    if let Some(dir) = cwd.filter(|d| d.is_dir()) {
        cmd.current_dir(dir);
    }
    unsafe {
        cmd.pre_exec(|| {
            libc::setsid();
            Ok(())
        });
    }
    let mut child = cmd.spawn()?;
    std::thread::spawn(move || {
        let _ = child.wait();
    });
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn natural_order() {
        let mut v = vec!["img10.png", "img2.png", "Img1.png", "árbol", "zeta", "Banana"];
        v.sort_by(|a, b| natural_cmp(a, b));
        assert_eq!(v, ["árbol", "Banana", "Img1.png", "img2.png", "img10.png", "zeta"]);
    }

    #[test]
    fn uri_matches_glib() {
        assert_eq!(uri(Path::new("/home/a b/Imágenes/x#1.png")), "file:///home/a%20b/Im%C3%A1genes/x%231.png");
        assert_eq!(uri(Path::new("/t/a+b=c@d!(e)&f,g:h'~")), "file:///t/a+b=c@d!(e)&f,g:h'~");
        assert_eq!(path_from_uri("file:///home/a%20b").unwrap(), PathBuf::from("/home/a b"));
    }

    #[test]
    fn extensions() {
        assert_eq!(split_ext("a.tar.gz"), ("a", ".tar.gz"));
        assert_eq!(split_ext(".bashrc"), (".bashrc", ""));
        assert_eq!(split_ext("photo.JPG"), ("photo", ".JPG"));
    }

    #[test]
    fn free_names() {
        let dir = std::env::temp_dir().join(format!("inir-files-free-{}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        std::fs::write(dir.join("a.txt"), "").unwrap();
        std::fs::write(dir.join("a (2).txt"), "").unwrap();
        assert_eq!(free_name(&dir, "a.txt"), dir.join("a (3).txt"));
        assert_eq!(free_name(&dir, "a (2).txt"), dir.join("a (3).txt"));
        std::fs::remove_dir_all(&dir).unwrap();
    }
}
