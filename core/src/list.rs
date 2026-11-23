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
    Some(v)
}

pub fn dot_hidden(dir: &Path) -> HashSet<String> {
    fs::read_to_string(dir.join(".hidden")).map(|t| t.lines().map(|l| l.trim().to_string()).filter(|l| !l.is_empty()).collect()).unwrap_or_default()
}

pub fn sort(entries: &mut [Value], key: &str, desc: bool, dirs_first: bool) {
    let name = |v: &Value| v["name"].as_str().unwrap_or("").to_string();
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
        let ord = ord.then_with(|| util::natural_cmp(&name(a), &name(b)));
        if desc { ord.reverse() } else { ord }
    });
}

pub fn list(ctx: &Arc<Ctx>, req: &Value) -> Result<Value, String> {
    let raw = req["path"].as_str().unwrap_or("");
    let path = PathBuf::from(if raw.is_empty() { util::home().to_string_lossy().into_owned() } else { raw.to_string() });
    let show_hidden = req["hidden"].as_bool().unwrap_or(false);
    let rd = fs::read_dir(&path).map_err(|e| error_code(&e))?;
    let roles = crate::places::roles();
    let dh = dot_hidden(&path);
    let mut entries = Vec::new();
    let mut hidden = 0;
    for de in rd.flatten() {
        let p = de.path();
        let Some(v) = entry(ctx, &p, &roles, &dh) else { continue };
        if v["hidden"].as_bool().unwrap_or(false) {
            hidden += 1;
            if !show_hidden {
                continue;
            }
        }
        entries.push(v);
    }
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
    if !remote && req["counts"].as_bool().unwrap_or(true) {
        let dirs: Vec<PathBuf> = entries.iter().filter(|e| e["dir"].as_bool().unwrap_or(false)).map(|e| PathBuf::from(e["path"].as_str().unwrap_or(""))).collect();
        if !dirs.is_empty() {
            let ctx = ctx.clone();
            let folder = path.to_string_lossy().into_owned();
            std::thread::spawn(move || counts(&ctx, &folder, dirs, show_hidden));
        }
    }
    Ok(json!({
        "path": path.to_string_lossy(),
        "entries": entries,
        "hidden": hidden,
        "writable": util::can_write(&path),
        "space": {"total": total, "free": free},
        "remote": remote,
    }))
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
