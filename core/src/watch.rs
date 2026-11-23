// Folders on screen stay true to the disk: inotify on each folder a view shows, with changes held until the folder is
// quiet for 200 ms (or a second has passed, so a long copy still shows progress). Places (drives plugged in, mounts,
// network shares, bookmarks edited elsewhere, the trash) are checked every two seconds against a cheap signature.

use crate::util;
use crate::Ctx;
use notify::{EventKind, RecommendedWatcher, RecursiveMode, Watcher};
use serde_json::{json, Value};
use std::collections::HashSet;
use std::fs;
use std::path::PathBuf;
use std::sync::{mpsc, Arc, Mutex};
use std::time::{Duration, Instant};

#[derive(Default)]
pub struct Watch {
    watcher: Mutex<Option<RecommendedWatcher>>,
    set: Mutex<HashSet<PathBuf>>,
}

pub fn start(ctx: Arc<Ctx>) {
    let (tx, rx) = mpsc::channel::<PathBuf>();
    let watcher = notify::recommended_watcher(move |res: notify::Result<notify::Event>| {
        let Ok(ev) = res else { return };
        if matches!(ev.kind, EventKind::Access(_)) {
            return;
        }
        for p in ev.paths {
            let _ = tx.send(p);
        }
    });
    if let Ok(w) = watcher {
        *ctx.watch.watcher.lock().unwrap() = Some(w);
    }
    let c = ctx.clone();
    std::thread::spawn(move || debounce(&c, rx));
    std::thread::spawn(move || places_poll(&ctx));
}

fn debounce(ctx: &Ctx, rx: mpsc::Receiver<PathBuf>) {
    while let Ok(first) = rx.recv() {
        let mut changed = vec![first];
        let began = Instant::now();
        let mut quiet_from = Instant::now();
        loop {
            let left = Duration::from_millis(200).saturating_sub(quiet_from.elapsed()).min(Duration::from_millis(1000).saturating_sub(began.elapsed()));
            if left.is_zero() {
                break;
            }
            match rx.recv_timeout(left) {
                Ok(p) => {
                    changed.push(p);
                    quiet_from = Instant::now();
                }
                Err(mpsc::RecvTimeoutError::Timeout) => break,
                Err(mpsc::RecvTimeoutError::Disconnected) => return,
            }
        }
        let set = ctx.watch.set.lock().unwrap().clone();
        let mut dirs: Vec<String> = Vec::new();
        for p in changed {
            // A part file is a copy at work: the finished file announces itself when it is renamed.
            if util::name_of(&p).ends_with(".inir-part") {
                continue;
            }
            let dir = if set.contains(&p) { p } else { p.parent().map(|d| d.to_path_buf()).unwrap_or(p) };
            let s = dir.to_string_lossy().into_owned();
            if set.contains(&dir) && !dirs.contains(&s) {
                dirs.push(s);
            }
        }
        if !dirs.is_empty() {
            ctx.out.event("changed", json!({"paths": dirs}));
        }
    }
}

/// The folders watched become exactly these.
pub fn set(ctx: &Ctx, req: &Value) -> Value {
    let want: HashSet<PathBuf> = req["paths"].as_array().into_iter().flatten().filter_map(|p| p.as_str()).filter(|p| !p.is_empty()).map(PathBuf::from).collect();
    let mut guard = ctx.watch.watcher.lock().unwrap();
    let Some(w) = guard.as_mut() else { return json!({"watching": 0}) };
    let mut set = ctx.watch.set.lock().unwrap();
    for gone in set.difference(&want).cloned().collect::<Vec<_>>() {
        let _ = w.unwatch(&gone);
        set.remove(&gone);
    }
    // A network folder is not watched: inotify sees only this machine's changes there, and costs a round trip.
    for p in want.difference(&set.clone()).cloned().collect::<Vec<_>>() {
        if !util::is_remote(&p) && w.watch(&p, RecursiveMode::NonRecursive).is_ok() {
            set.insert(p);
        }
    }
    json!({"watching": set.len()})
}

fn signature() -> String {
    let mut s = fs::read_to_string("/proc/self/mountinfo").unwrap_or_default();
    for dir in [PathBuf::from("/dev/disk/by-id"), crate::util::gvfs_dir()] {
        if let Ok(rd) = fs::read_dir(&dir) {
            let mut names: Vec<String> = rd.flatten().map(|e| e.file_name().to_string_lossy().into_owned()).collect();
            names.sort();
            s.push_str(&names.join("|"));
        }
    }
    let stamp = |p: PathBuf| fs::metadata(p).and_then(|m| m.modified()).map(|t| format!("{t:?}")).unwrap_or_default();
    s.push_str(&stamp(util::config_home().join("gtk-3.0/bookmarks")));
    s.push_str(&stamp(util::data_home().join("Trash/info")));
    s.push_str(&stamp(util::data_home().join("user-dirs.dirs")));
    s.push_str(&stamp(util::config_home().join("user-dirs.dirs")));
    s
}

fn places_poll(ctx: &Ctx) {
    let mut last = signature();
    loop {
        std::thread::sleep(Duration::from_secs(2));
        let now = signature();
        if now != last {
            last = now;
            ctx.out.event("places", crate::places::places());
        }
    }
}
