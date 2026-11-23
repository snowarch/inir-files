// The side column's places: the person's folders (user-dirs.dirs, in their language), GTK bookmarks (shared with every
// file chooser), drives from lsblk with their space, network and FUSE mounts, the trash, and the recent files list.

use crate::util;
use crate::Ctx;
use serde_json::{json, Value};
use std::collections::{HashMap, HashSet};
use std::fs;
use std::path::{Path, PathBuf};

const ROLES: &[(&str, &str)] = &[
    ("XDG_DESKTOP_DIR", "desktop"), ("XDG_DOCUMENTS_DIR", "documents"), ("XDG_DOWNLOAD_DIR", "downloads"),
    ("XDG_MUSIC_DIR", "music"), ("XDG_PICTURES_DIR", "pictures"), ("XDG_VIDEOS_DIR", "videos"),
    ("XDG_TEMPLATES_DIR", "templates"), ("XDG_PUBLICSHARE_DIR", "public"),
];

pub fn xdg_dirs() -> Vec<(&'static str, PathBuf)> {
    let home = util::home();
    let text = fs::read_to_string(util::config_home().join("user-dirs.dirs")).unwrap_or_default();
    let mut out = Vec::new();
    for (key, role) in ROLES {
        let found = text.lines().find_map(|l| l.trim().strip_prefix(&format!("{key}=")).map(|v| v.trim().trim_matches('"').to_string()));
        let path = match found {
            Some(v) => PathBuf::from(v.replace("$HOME", &home.to_string_lossy())),
            None => continue,
        };
        if path != home && path.is_dir() {
            out.push((*role, path));
        }
    }
    out
}

pub fn roles() -> HashMap<PathBuf, &'static str> {
    let mut m: HashMap<PathBuf, &'static str> = xdg_dirs().into_iter().map(|(r, p)| (p, r)).collect();
    m.insert(util::home(), "home");
    m
}

fn bookmarks_file() -> PathBuf {
    util::config_home().join("gtk-3.0/bookmarks")
}

pub fn bookmarks() -> Vec<Value> {
    let text = fs::read_to_string(bookmarks_file()).unwrap_or_default();
    text.lines().filter_map(|l| {
        let (uri, name) = l.split_once(' ').map(|(u, n)| (u, n.trim().to_string())).unwrap_or((l.trim(), String::new()));
        if uri.starts_with("file://") {
            let p = util::path_from_uri(uri)?;
            let label = if name.is_empty() { util::name_of(&p) } else { name };
            Some(json!({"path": p.to_string_lossy(), "name": label, "exists": p.exists(), "remote": false}))
        } else if !uri.is_empty() {
            // sftp://, smb:// ...: kept as they are, opened through gio.
            Some(json!({"path": uri, "name": if name.is_empty() { uri.to_string() } else { name }, "exists": true, "remote": true}))
        } else {
            None
        }
    }).collect()
}

fn write_bookmarks(list: &[(String, String)]) -> Result<(), String> {
    let file = bookmarks_file();
    if let Some(dir) = file.parent() {
        fs::create_dir_all(dir).map_err(|e| e.to_string())?;
    }
    let text: String = list.iter().map(|(p, n)| {
        let uri = if p.contains("://") { p.clone() } else { util::uri(Path::new(p)) };
        let default = util::name_of(Path::new(p));
        if n.is_empty() || *n == default { format!("{uri}\n") } else { format!("{uri} {n}\n") }
    }).collect();
    let tmp = file.with_extension("inir-tmp");
    fs::write(&tmp, text).map_err(|e| e.to_string())?;
    fs::rename(&tmp, &file).map_err(|e| e.to_string())
}

pub fn bookmark_op(op: &str, req: &Value) -> Result<Value, String> {
    let mut list: Vec<(String, String)> = bookmarks().iter().map(|b| (b["path"].as_str().unwrap_or("").to_string(), b["name"].as_str().unwrap_or("").to_string())).collect();
    let path = req["path"].as_str().unwrap_or("").to_string();
    match op {
        "bookmark_add" => {
            if !list.iter().any(|(p, _)| *p == path) {
                let at = req["at"].as_i64().map(|a| a.clamp(0, list.len() as i64) as usize).unwrap_or(list.len());
                list.insert(at, (path.clone(), util::name_of(Path::new(&path))));
            }
        }
        "bookmark_remove" => list.retain(|(p, _)| *p != path),
        "bookmark_rename" => {
            if let Some(b) = list.iter_mut().find(|(p, _)| *p == path) {
                b.1 = req["name"].as_str().unwrap_or("").to_string();
            }
        }
        "bookmark_move" => {
            if let Some(from) = list.iter().position(|(p, _)| *p == path) {
                let item = list.remove(from);
                let to = req["at"].as_i64().unwrap_or(0).clamp(0, list.len() as i64) as usize;
                list.insert(to, item);
            }
        }
        _ => return Err("unknown".into()),
    }
    write_bookmarks(&list)?;
    Ok(json!({"bookmarks": bookmarks()}))
}

fn flatten(dev: &Value, parent: Option<&Value>, out: &mut Vec<(Value, Option<Value>)>) {
    out.push((dev.clone(), parent.cloned()));
    for child in dev["children"].as_array().into_iter().flatten() {
        flatten(child, Some(parent.unwrap_or(dev)), out);
    }
}

/// The mount points that show a filesystem whole. A folder of it bound somewhere else (a bind mount, or a btrfs
/// subvolume) lists the same device in lsblk, often first, and is not where the disk opens.
fn whole_mounts() -> HashSet<String> {
    let text = fs::read_to_string("/proc/self/mountinfo").unwrap_or_default();
    text.lines()
        .filter_map(|l| {
            let mut f = l.split(' ');
            let root = f.nth(3)?;
            let at = f.next()?;
            (root == "/").then(|| at.replace("\\040", " ").replace("\\011", "\t").replace("\\012", "\n").replace("\\134", "\\"))
        })
        .collect()
}

/// Where a disk opens: of its mount points outside the system's own, the one that shows it whole, the shortest first.
fn pick_mount(mounts: &[String], whole: &HashSet<String>) -> Option<String> {
    let mut found: Vec<&String> = mounts.iter().filter(|m| !SYSTEM_MOUNTS.contains(&m.as_str()) && !m.starts_with("/boot") && *m != "[SWAP]").collect();
    found.sort_by_key(|m| (!whole.contains(*m), m.len()));
    found.first().map(|m| (*m).clone())
}

const SYSTEM_MOUNTS: &[&str] = &["/boot", "/efi", "/boot/efi", "/recovery", "/var", "/tmp", "/srv", "/opt", "/usr", "/root", "/nix", "/snap", "/.snapshots", "/var/log", "/var/cache", "/var/tmp", "/home"];

pub fn devices() -> Vec<Value> {
    let Some(raw) = util::run_out("lsblk", &["-J", "-b", "-o", "NAME,PATH,LABEL,PARTLABEL,SIZE,FSTYPE,MOUNTPOINTS,HOTPLUG,RM,TYPE,UUID,MODEL,TRAN,RO"], 3000) else { return Vec::new() };
    let Ok(tree) = serde_json::from_str::<Value>(&raw) else { return Vec::new() };
    let mut all = Vec::new();
    for d in tree["blockdevices"].as_array().into_iter().flatten() {
        flatten(d, None, &mut all);
    }
    let root_dev = all.iter().find(|(d, _)| d["mountpoints"].as_array().map(|m| m.iter().any(|x| x == "/")).unwrap_or(false)).map(|(d, _)| d["path"].clone());
    let mut out = Vec::new();
    let mut seen_uuid = HashSet::new();
    let whole = whole_mounts();
    for (d, disk) in all {
        let fstype = d["fstype"].as_str().unwrap_or("");
        if fstype.is_empty() || ["swap", "crypto_LUKS", "LVM2_member", "linux_raid_member", "zfs_member", "squashfs"].contains(&fstype) {
            continue;
        }
        if matches!(d["type"].as_str(), Some("loop")) {
            continue;
        }
        let uuid = d["uuid"].as_str().unwrap_or("").to_string();
        if !uuid.is_empty() && !seen_uuid.insert(uuid.clone()) {
            continue;
        }
        let mounts: Vec<String> = d["mountpoints"].as_array().into_iter().flatten().filter_map(|m| m.as_str()).map(str::to_string).collect();
        let is_root = mounts.iter().any(|m| m == "/");
        let mount = if is_root { Some("/".to_string()) } else { pick_mount(&mounts, &whole) };
        let disk = disk.unwrap_or_else(|| d.clone());
        let removable = disk["hotplug"].as_bool().unwrap_or(false) || disk["rm"].as_bool().unwrap_or(false) || disk["tran"].as_str() == Some("usb");
        // The system's own partitions (/boot, /efi, a second subvolume of the root) stay out of the way.
        if mount.is_none() && !mounts.is_empty() {
            continue;
        }
        if !is_root && d["path"] == root_dev.clone().unwrap_or_default() {
            continue;
        }
        let (size, free) = mount.as_ref().and_then(|m| util::fs_space(Path::new(m))).unwrap_or((d["size"].as_u64().unwrap_or(0), 0));
        let label = d["label"].as_str().or(d["partlabel"].as_str()).unwrap_or("").to_string();
        out.push(json!({
            "device": d["path"], "drive": disk["path"], "label": label, "model": disk["model"].as_str().unwrap_or("").trim(),
            "fstype": fstype, "path": mount.clone().unwrap_or_default(), "mounted": mount.is_some(), "root": is_root,
            "size": size, "free": free, "removable": removable, "readonly": d["ro"].as_bool().unwrap_or(false),
            "tran": disk["tran"].as_str().unwrap_or(""),
        }));
    }
    out.sort_by_key(|d| (!d["root"].as_bool().unwrap_or(false), d["removable"].as_bool().unwrap_or(false), d["label"].as_str().unwrap_or("").to_lowercase()));
    out
}

/// Network shares and FUSE mounts: sshfs, rclone, SMB, NFS, and what GVfs exposes (phones over MTP, smb:// shares).
pub fn network() -> Vec<Value> {
    let mut out = Vec::new();
    let text = fs::read_to_string("/proc/self/mountinfo").unwrap_or_default();
    for line in text.lines() {
        let Some((left, right)) = line.split_once(" - ") else { continue };
        let mount = left.split(' ').nth(4).unwrap_or("").replace("\\040", " ");
        let mut r = right.split(' ');
        let fstype = r.next().unwrap_or("");
        let source = r.next().unwrap_or("").replace("\\040", " ");
        let net = ["cifs", "smb3", "nfs", "nfs4", "fuse.sshfs", "fuse.rclone", "9p", "fuse.s3fs", "davfs", "fuse.davfs2"].contains(&fstype);
        if net {
            let (size, free) = util::fs_space(Path::new(&mount)).unwrap_or((0, 0));
            out.push(json!({"path": mount, "label": util::name_of(Path::new(&mount)), "source": source, "fstype": fstype, "size": size, "free": free, "kind": "share"}));
        }
    }
    let uid = unsafe { libc::getuid() };
    let gvfs = PathBuf::from(format!("/run/user/{uid}/gvfs"));
    if let Ok(rd) = fs::read_dir(&gvfs) {
        for de in rd.flatten() {
            let name = de.file_name().to_string_lossy().into_owned();
            let (scheme, rest) = name.split_once(':').unwrap_or(("", &name));
            let host = rest.split(',').find_map(|kv| kv.strip_prefix("host=").or_else(|| kv.strip_prefix("server="))).unwrap_or(rest);
            let share = rest.split(',').find_map(|kv| kv.strip_prefix("share=")).unwrap_or("");
            let label = percent_encoding::percent_decode_str(&if share.is_empty() { host.to_string() } else { format!("{share} on {host}") }).decode_utf8_lossy().replace('_', " ");
            out.push(json!({"path": de.path().to_string_lossy(), "label": label, "source": name, "fstype": scheme, "size": 0, "free": 0, "kind": if scheme == "mtp" || scheme == "gphoto2" { "phone" } else { "share" }}));
        }
    }
    out
}

pub fn trash_count() -> usize {
    fs::read_dir(util::data_home().join("Trash/files")).map(|rd| rd.count()).unwrap_or(0)
}

pub fn places() -> Value {
    let home = util::home();
    json!({
        "home": home.to_string_lossy(),
        "user": util::user_name(unsafe { libc::getuid() }),
        "host": fs::read_to_string("/etc/hostname").or_else(|_| fs::read_to_string("/proc/sys/kernel/hostname")).unwrap_or_default().trim(),
        "xdg": xdg_dirs().into_iter().map(|(r, p)| json!({"role": r, "path": p.to_string_lossy(), "name": util::name_of(&p)})).collect::<Vec<_>>(),
        "bookmarks": bookmarks(),
        "devices": devices(),
        "network": network(),
        "trash": trash_count(),
        "trashDir": util::data_home().join("Trash/files").to_string_lossy(),
    })
}

pub fn mount(req: &Value) -> Result<Value, String> {
    let device = req["device"].as_str().unwrap_or("");
    let out = std::process::Command::new("udisksctl").args(["mount", "-b", device]).output().map_err(|e| e.to_string())?;
    let text = String::from_utf8_lossy(&out.stdout).to_string();
    if !out.status.success() {
        return Err(String::from_utf8_lossy(&out.stderr).trim().to_string());
    }
    // "Mounted /dev/sdb1 at /run/media/user/LABEL"
    let path = text.split(" at ").nth(1).map(|s| s.trim().trim_end_matches('.').to_string()).unwrap_or_default();
    Ok(json!({"path": path}))
}

pub fn unmount(req: &Value) -> Result<Value, String> {
    let device = req["device"].as_str().unwrap_or("");
    let path = req["path"].as_str().unwrap_or("");
    let (ok, err) = if !device.is_empty() {
        util::run_status("udisksctl", &["unmount", "-b", device])
    } else if path.contains("/gvfs/") {
        util::run_status("gio", &["mount", "-u", path])
    } else {
        util::run_status("fusermount3", &["-u", path])
    };
    if !ok {
        return Err(if err.contains("busy") || err.contains("target is busy") { "busy".into() } else { err });
    }
    if req["eject"].as_bool().unwrap_or(false) {
        if let Some(drive) = req["drive"].as_str().filter(|d| !d.is_empty()) {
            let (ok, err) = util::run_status("udisksctl", &["power-off", "-b", drive]);
            if !ok {
                return Err(err);
            }
        }
    }
    Ok(json!({}))
}

/// Recently used files (recently-used.xbel, written by GTK and Qt apps alike), newest first.
pub fn recent(ctx: &Ctx) -> Value {
    let text = fs::read_to_string(util::data_home().join("recently-used.xbel")).unwrap_or_default();
    let mut items: Vec<(String, PathBuf)> = Vec::new();
    for chunk in text.split("<bookmark ").skip(1) {
        let attr = |name: &str| chunk.split(&format!("{name}=\"")).nth(1).and_then(|s| s.split('"').next()).unwrap_or("").to_string();
        let href = attr("href").replace("&amp;", "&");
        let Some(p) = util::path_from_uri(&href) else { continue };
        let when = [attr("visited"), attr("modified"), attr("added")].into_iter().max().unwrap_or_default();
        items.push((when, p));
    }
    items.sort_by(|a, b| b.0.cmp(&a.0));
    let mut seen = std::collections::HashSet::new();
    let paths: Vec<PathBuf> = items.into_iter().filter(|(_, p)| p.exists() && seen.insert(p.clone())).take(300).map(|(_, p)| p).collect();
    let mut entries = crate::list::stat_many(ctx, &paths);
    for (i, e) in entries.iter_mut().enumerate() {
        e["order"] = json!(i);
    }
    json!({"entries": entries})
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_disk_opens_where_it_is_whole() {
        let mounts: Vec<String> = ["/home/a/Wallpapers", "/home/a/Downloads", "/mnt/games"].iter().map(|s| s.to_string()).collect();
        let whole: HashSet<String> = ["/mnt/games".to_string(), "/".to_string()].into_iter().collect();
        assert_eq!(pick_mount(&mounts, &whole).as_deref(), Some("/mnt/games"));
    }

    #[test]
    fn with_no_whole_mount_the_shortest_wins() {
        let mounts: Vec<String> = ["/srv", "/data/sub/deep", "/data/sub"].iter().map(|s| s.to_string()).collect();
        assert_eq!(pick_mount(&mounts, &HashSet::new()).as_deref(), Some("/data/sub"));
    }
}
