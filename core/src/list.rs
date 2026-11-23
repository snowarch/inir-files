// A folder's entries, described once in the shape every view reads (the grid, the list, search, recent, trash), sorted
// in the core so a large folder arrives in order.

use crate::util;
use crate::Ctx;
use serde_json::{json, Value};
use std::collections::{HashMap, HashSet};
use std::fs;
use std::os::unix::fs::{MetadataExt, PermissionsExt};
use std::path::{Path, PathBuf};
use std::sync::Arc;

pub fn error_code(e: &std::io::Error) -> String {
    use std::io::ErrorKind::*;
    match e.kind() {
        NotFound => "missing".into(),
        PermissionDenied => "denied".into(),
        NotADirectory => "notdir".into(),
        AlreadyExists => "exists".into(),
        DirectoryNotEmpty => "notempty".into(),
        ReadOnlyFilesystem => "readonly".into(),
        StorageFull => "full".into(),
        CrossesDevices => "crossdevice".into(),
        InvalidFilename => "badname".into(),
        _ => e.to_string(),
    }
}

/// One entry. None only when the name vanished between reading the folder and looking at it.
pub fn entry(ctx: &Ctx, path: &Path, roles: &HashMap<PathBuf, &'static str>, dot_hidden: &HashSet<String>) -> Option<Value> {
    let name = util::name_of(path);
    let lmeta = fs::symlink_metadata(path).ok()?;
    let link = lmeta.file_type().is_symlink();
    let (meta, broken) = if link {
        match fs::metadata(path) {
            Ok(m) => (m, false),
            Err(_) => (lmeta.clone(), true),
        }
    } else {
        (lmeta.clone(), false)
    };
    let dir = meta.is_dir();
    let mode = meta.permissions().mode();
    let mime = if dir {
        "inode/directory".to_string()
    } else if broken {
        "inode/symlink".to_string()
    } else if meta.file_type().is_file() {
        ctx.mime.of_file(path, &name, meta.len())
    } else {
        use std::os::unix::fs::FileTypeExt;
        let ft = meta.file_type();
        if ft.is_fifo() { "inode/fifo" } else if ft.is_socket() { "inode/socket" } else if ft.is_block_device() { "inode/blockdevice" } else { "inode/chardevice" }.to_string()
    };
    let kind = ctx.mime.kind(&mime);
    let (icon, generic) = if dir { ("folder".to_string(), "folder".to_string()) } else { ctx.mime.icons(&mime) };
    let mut v = json!({
        "name": name,
        "path": path.to_string_lossy(),
        "dir": dir,
        "link": link,
        "size": if dir { 0 } else { meta.len() },
        "mtime": util::millis(meta.modified()),
        "comment": ctx.mime.comment(&mime),
        "mime": mime,
        "kind": kind,
        "icon": icon,
        "generic": generic,
        "hidden": name.starts_with('.') || dot_hidden.contains(&name),
        "exec": !dir && meta.is_file() && mode & 0o111 != 0,
        "mode": mode & 0o7777,
        "uid": meta.uid(),
        "items": -1,
        "thumb": !dir && !broken && ctx.thumbs.can(&ctx.mime, &mime),
    });
    if link {
        v["target"] = json!(fs::read_link(path).map(|t| t.to_string_lossy().into_owned()).unwrap_or_default());
        v["broken"] = json!(broken);
    }
    if dir {
        if let Some(role) = roles.get(path) {
            v["role"] = json!(role);
        }
    }
    // A launcher wears its app's icon.
    if mime == "application/x-desktop" {
        if let Some(icon) = app_icon(path) {
            v["appIcon"] = json!(icon);
        }
    }
    Some(v)
}

/// The Icon= of a desktop entry's main group: a theme name or a path.
fn app_icon(path: &Path) -> Option<String> {
    use std::io::Read;
    let mut head = String::new();
    fs::File::open(path).ok()?.take(16 * 1024).read_to_string(&mut head).ok()?;
    desktop_icon(&head)
}

fn desktop_icon(text: &str) -> Option<String> {
    let mut main = false;
    for line in text.lines() {
        let line = line.trim();
        if line.starts_with('[') {
            if main {
                break;
            }
            main = line == "[Desktop Entry]";
        } else if let Some(icon) = line.strip_prefix("Icon=").filter(|_| main) {
            return Some(icon.trim().to_string()).filter(|i| !i.is_empty());
        }
    }
    None
}

pub fn dot_hidden(dir: &Path) -> HashSet<String> {
    fs::read_to_string(dir.join(".hidden")).map(|t| t.lines().map(|l| l.trim().to_string()).filter(|l| !l.is_empty()).collect()).unwrap_or_default()
}

pub fn sort(entries: &mut [Value], key: &str, desc: bool, dirs_first: bool) {
    fn name(v: &Value) -> &str {
        v["name"].as_str().unwrap_or("")
    }
    entries.sort_by(|a, b| {
        if dirs_first {
            let (da, db) = (a["dir"].as_bool().unwrap_or(false), b["dir"].as_bool().unwrap_or(false));
            if da != db {
                return db.cmp(&da);
            }
        }
        let ord = match key {
            "size" => {
                let s = |v: &Value| if v["dir"].as_bool().unwrap_or(false) { v["items"].as_i64().unwrap_or(-1) as f64 } else { v["size"].as_f64().unwrap_or(0.0) };
                s(a).partial_cmp(&s(b)).unwrap_or(std::cmp::Ordering::Equal)
            }
            "mtime" => a["mtime"].as_f64().unwrap_or(0.0).partial_cmp(&b["mtime"].as_f64().unwrap_or(0.0)).unwrap_or(std::cmp::Ordering::Equal),
            "kind" => a["kind"].as_str().cmp(&b["kind"].as_str()).then_with(|| a["mime"].as_str().cmp(&b["mime"].as_str())),
            "ext" => {
                let e = |v: &Value| util::split_ext(v["name"].as_str().unwrap_or("")).1.to_lowercase();
                e(a).cmp(&e(b))
            }
            _ => std::cmp::Ordering::Equal,
        };
        let ord = ord.then_with(|| util::natural_cmp(name(a), name(b)));
        if desc { ord.reverse() } else { ord }
    });
}

/// The folder sizes a listing asks for: counted after its reply has gone out, so the first count never arrives before
/// the rows it belongs to.
pub struct Counts {
    folder: String,
    dirs: Vec<PathBuf>,
    hidden: bool,
}

impl Counts {
    pub fn spawn(self, ctx: &Arc<Ctx>) {
        let ctx = ctx.clone();
        std::thread::spawn(move || counts(&ctx, &self.folder, self.dirs, self.hidden));
    }
}

// A folder this large is read on every core: each entry costs a stat, and a name without a type costs a read.
const SPLIT_AT: usize = 512;

pub fn list(ctx: &Arc<Ctx>, req: &Value) -> Result<(Value, Option<Counts>), String> {
    let raw = req["path"].as_str().unwrap_or("");
    let path = PathBuf::from(if raw.is_empty() { util::home().to_string_lossy().into_owned() } else { raw.to_string() });
    let show_hidden = req["hidden"].as_bool().unwrap_or(false);
    let rd = fs::read_dir(&path).map_err(|e| error_code(&e))?;
    let roles = crate::places::roles();
    let dh = dot_hidden(&path);
    let names: Vec<PathBuf> = rd.flatten().map(|de| de.path()).collect();
    let read = |part: &[PathBuf]| part.iter().filter_map(|p| entry(ctx, p, &roles, &dh)).collect::<Vec<_>>();
    let all: Vec<Value> = if names.len() < SPLIT_AT {
        read(&names)
    } else {
        let threads = std::thread::available_parallelism().map(|n| n.get()).unwrap_or(4).clamp(2, 8);
        let chunk = names.len().div_ceil(threads);
        std::thread::scope(|s| {
            let parts: Vec<_> = names.chunks(chunk).map(|part| s.spawn(|| read(part))).collect();
            parts.into_iter().flat_map(|h| h.join().unwrap_or_default()).collect()
        })
    };
    let hidden = all.iter().filter(|v| v["hidden"].as_bool().unwrap_or(false)).count();
    let mut entries: Vec<Value> = if show_hidden { all } else { all.into_iter().filter(|v| !v["hidden"].as_bool().unwrap_or(false)).collect() };
    sort(&mut entries, req["sort"].as_str().unwrap_or("name"), req["desc"].as_bool().unwrap_or(false), req["dirsFirst"].as_bool().unwrap_or(true));
    let (total, free) = util::fs_space(&path).unwrap_or((0, 0));
    let remote = util::is_remote(&path);
    // Each entry of a network folder says so: previews set to "This computer" pass it by.
    if remote {
        for e in entries.iter_mut() {
            e["remote"] = json!(true);
        }
    }
    // Each folder's item count follows, read off the reply's thread: a folder of folders shows at once.
    let mut follow = None;
    if !remote && req["counts"].as_bool().unwrap_or(true) {
        let dirs: Vec<PathBuf> = entries.iter().filter(|e| e["dir"].as_bool().unwrap_or(false)).map(|e| PathBuf::from(e["path"].as_str().unwrap_or(""))).collect();
        if !dirs.is_empty() {
            follow = Some(Counts { folder: path.to_string_lossy().into_owned(), dirs, hidden: show_hidden });
        }
    }
    let reply = json!({
        "path": path.to_string_lossy(),
        "entries": entries,
        "hidden": hidden,
        "writable": util::can_write(&path),
        "space": {"total": total, "free": free},
        "remote": remote,
    });
    Ok((reply, follow))
}

fn counts(ctx: &Ctx, folder: &str, dirs: Vec<PathBuf>, show_hidden: bool) {
    let mut batch = serde_json::Map::new();
    let mut last = std::time::Instant::now();
    for d in dirs {
        let n = fs::read_dir(&d).map(|rd| rd.flatten().filter(|e| show_hidden || !e.file_name().to_string_lossy().starts_with('.')).count() as i64).unwrap_or(-1);
        batch.insert(util::name_of(&d), json!(n));
        if last.elapsed().as_millis() > 120 {
            ctx.out.event("counts", json!({"path": folder, "counts": std::mem::take(&mut batch)}));
            last = std::time::Instant::now();
        }
    }
    if !batch.is_empty() {
        ctx.out.event("counts", json!({"path": folder, "counts": batch}));
    }
}

/// Entries for paths anywhere (a selection's details, the recent list, a paste).
pub fn stat_many(ctx: &Ctx, paths: &[PathBuf]) -> Vec<Value> {
    let roles = crate::places::roles();
    let empty = HashSet::new();
    paths.iter().filter_map(|p| entry(ctx, p, &roles, &empty)).collect()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_launcher_names_its_main_icon() {
        let text = "[Desktop Action new]\nIcon=other\n[Desktop Entry]\nName=Editor\nIcon= org.app.Editor \n[Desktop Action x]\nIcon=late\n";
        assert_eq!(desktop_icon(text).as_deref(), Some("org.app.Editor"));
        assert_eq!(desktop_icon("[Desktop Entry]\nIcon=\n"), None);
        assert_eq!(desktop_icon("[Desktop Entry]\nName=x\n[Other]\nIcon=y\n"), None);
    }
}
