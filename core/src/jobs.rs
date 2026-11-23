// Everything that changes files and can take time: copy, move, link, trash, delete, restore, extract, compress. Each is
// a job on its own thread with progress (bytes, files, rate), a question when a name is taken, cancel at any point
// (a file being written is dropped, never left half), and what it changed, so the interface can undo it.

use crate::list::error_code;
use crate::util;
use crate::Ctx;
use serde_json::{json, Value};
use std::collections::HashMap;
use std::fs;
use std::io::{Read, Write};
use std::os::unix::fs::{MetadataExt, PermissionsExt};
use std::os::unix::io::AsRawFd;
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::sync::{mpsc, Arc, Mutex};
use std::time::Instant;

#[derive(Default)]
pub struct Registry {
    next: AtomicU64,
    jobs: Mutex<HashMap<u64, Arc<Ctl>>>,
}

pub struct Ctl {
    cancel: AtomicBool,
    answers: Mutex<Option<mpsc::Sender<(String, bool)>>>,
}

impl Registry {
    pub fn cancel(&self, id: u64) {
        if let Some(c) = self.jobs.lock().unwrap().get(&id) {
            c.cancel.store(true, Ordering::Relaxed);
            // A job waiting on a question stops waiting.
            if let Some(tx) = c.answers.lock().unwrap().as_ref() {
                let _ = tx.send(("cancel".into(), false));
            }
        }
    }

    pub fn active(&self) -> usize {
        self.jobs.lock().unwrap().len()
    }

    pub fn resolve(&self, id: u64, action: String, all: bool) {
        if let Some(c) = self.jobs.lock().unwrap().get(&id) {
            if let Some(tx) = c.answers.lock().unwrap().as_ref() {
                let _ = tx.send((action, all));
            }
        }
    }
}

struct Cancelled;

struct Run<'a> {
    ctx: &'a Ctx,
    id: u64,
    kind: String,
    ctl: Arc<Ctl>,
    rx: mpsc::Receiver<(String, bool)>,
    total_bytes: u64,
    total_files: u64,
    bytes: u64,
    files: u64,
    current: String,
    state: &'static str,
    started: Instant,
    last: Instant,
    rate: f64,
    rate_mark: (Instant, u64),
    policy: Option<String>,
    errors: Vec<Value>,
    created: Vec<String>,
    moved: Vec<(String, String)>,
    trashed: Vec<String>,
    untrashable: Vec<String>,
    dest: String,
}

impl<'a> Run<'a> {
    fn new(ctx: &'a Ctx, kind: &str, dest: &str) -> (u64, Self) {
        let id = ctx.jobs.next.fetch_add(1, Ordering::Relaxed) + 1;
        let (tx, rx) = mpsc::channel();
        let ctl = Arc::new(Ctl { cancel: AtomicBool::new(false), answers: Mutex::new(Some(tx)) });
        ctx.jobs.jobs.lock().unwrap().insert(id, ctl.clone());
        let now = Instant::now();
        (id, Run {
            ctx, id, kind: kind.into(), ctl, rx, total_bytes: 0, total_files: 0, bytes: 0, files: 0, current: String::new(),
            state: "scan", started: now, last: now, rate: 0.0, rate_mark: (now, 0), policy: None, errors: Vec::new(),
            created: Vec::new(), moved: Vec::new(), trashed: Vec::new(), untrashable: Vec::new(), dest: dest.into(),
        })
    }

    fn cancelled(&self) -> bool {
        self.ctl.cancel.load(Ordering::Relaxed)
    }

    fn progress(&self) -> f64 {
        if self.total_bytes == 0 && self.total_files == 0 {
            return -1.0;
        }
        // Bytes carry the weight, but every file costs something too: ten thousand empty files are not instant.
        let unit = 64.0 * 1024.0;
        let done = self.bytes as f64 + self.files as f64 * unit;
        let total = self.total_bytes as f64 + self.total_files as f64 * unit;
        (done / total.max(1.0)).min(1.0)
    }

    fn emit(&mut self, force: bool) {
        if !force && self.last.elapsed().as_millis() < 100 {
            return;
        }
        self.last = Instant::now();
        let dt = self.rate_mark.0.elapsed().as_secs_f64();
        if dt > 0.5 {
            let inst = (self.bytes.saturating_sub(self.rate_mark.1)) as f64 / dt;
            self.rate = if self.rate == 0.0 { inst } else { self.rate * 0.6 + inst * 0.4 };
            self.rate_mark = (Instant::now(), self.bytes);
        }
        let eta = if self.rate > 1.0 && self.total_bytes > self.bytes { (self.total_bytes - self.bytes) as f64 / self.rate } else { -1.0 };
        let mut v = json!({
            "job": self.id, "kind": self.kind, "state": self.state, "progress": self.progress(),
            "bytes": self.bytes, "totalBytes": self.total_bytes, "files": self.files, "totalFiles": self.total_files,
            "current": self.current, "rate": self.rate, "eta": eta, "dest": self.dest,
            "elapsed": self.started.elapsed().as_secs_f64(),
        });
        if matches!(self.state, "done" | "failed" | "cancelled") {
            v["errors"] = json!(self.errors);
            v["created"] = json!(self.created);
            v["moved"] = json!(self.moved);
            v["trashed"] = json!(self.trashed);
            v["untrashable"] = json!(self.untrashable);
        }
        self.ctx.out.event("job", v);
    }

    fn finish(mut self) {
        self.state = if self.cancelled() { "cancelled" } else if !self.errors.is_empty() && self.created.is_empty() && self.moved.is_empty() && self.trashed.is_empty() && self.files == 0 { "failed" } else { "done" };
        self.emit(true);
        self.ctx.jobs.jobs.lock().unwrap().remove(&self.id);
        *self.ctl.answers.lock().unwrap() = None;
    }

    fn error(&mut self, path: &Path, e: impl ToString) {
        self.errors.push(json!({"path": path.to_string_lossy(), "error": e.to_string()}));
    }

    /// What to do with a name that is taken: "replace", "skip", "keep" (both) or "merge" for two folders.
    fn ask(&mut self, src: &Path, dst: &Path, dirs: bool) -> Result<String, Cancelled> {
        if let Some(p) = &self.policy {
            return Ok(p.clone());
        }
        let entries = crate::list::stat_many(self.ctx, &[src.to_path_buf(), dst.to_path_buf()]);
        self.ctx.out.event("conflict", json!({"job": self.id, "kind": self.kind, "src": entries.first(), "dst": entries.get(1), "dirs": dirs}));
        self.state = "waiting";
        self.emit(true);
        let started = Instant::now();
        let answer = loop {
            match self.rx.recv_timeout(std::time::Duration::from_millis(200)) {
                Ok(a) => break a,
                Err(mpsc::RecvTimeoutError::Timeout) if self.cancelled() => return Err(Cancelled),
                Err(mpsc::RecvTimeoutError::Timeout) => continue,
                Err(_) => return Err(Cancelled),
            }
        };
        // Time spent on the question is not time spent copying.
        self.rate_mark = (Instant::now(), self.bytes);
        let _ = started;
        self.state = "running";
        if answer.0 == "cancel" {
            self.ctl.cancel.store(true, Ordering::Relaxed);
            return Err(Cancelled);
        }
        if answer.1 {
            self.policy = Some(answer.0.clone());
        }
        Ok(answer.0)
    }

    fn scan(&mut self, paths: &[PathBuf]) {
        let mut stack: Vec<PathBuf> = paths.to_vec();
        while let Some(p) = stack.pop() {
            if self.cancelled() {
                return;
            }
            let Ok(m) = fs::symlink_metadata(&p) else { continue };
            self.total_files += 1;
            if m.is_dir() {
                if let Ok(rd) = fs::read_dir(&p) {
                    stack.extend(rd.flatten().map(|d| d.path()));
                }
            } else if m.is_file() {
                self.total_bytes += m.len();
            }
            self.emit(false);
        }
    }

    fn copy_data(&mut self, src: &Path, dst: &Path) -> std::io::Result<()> {
        let mut fin = fs::File::open(src)?;
        let meta = fin.metadata()?;
        let len = meta.len();
        let mut fout = fs::OpenOptions::new().write(true).create_new(true).open(dst)?;
        let mut done = 0u64;
        let mut kernel = true;
        let mut buf: Vec<u8> = Vec::new();
        while done < len {
            if self.cancelled() {
                return Err(std::io::Error::new(std::io::ErrorKind::Interrupted, "cancelled"));
            }
            let want = (len - done).min(32 << 20) as usize;
            let n = if kernel {
                // copy_file_range: a reflink on Btrfs and XFS, a server-side copy on NFS, a kernel copy elsewhere.
                let r = unsafe { libc::copy_file_range(fin.as_raw_fd(), std::ptr::null_mut(), fout.as_raw_fd(), std::ptr::null_mut(), want, 0) };
                if r < 0 {
                    let e = std::io::Error::last_os_error();
                    match e.raw_os_error() {
                        Some(libc::EXDEV) | Some(libc::EINVAL) | Some(libc::ENOSYS) | Some(libc::EOPNOTSUPP) | Some(libc::EPERM) | Some(libc::EIO) if done == 0 => {
                            kernel = false;
                            continue;
                        }
                        _ => return Err(e),
                    }
                }
                r as usize
            } else {
                if buf.is_empty() {
                    buf = vec![0u8; 1 << 20];
                }
                let r = fin.read(&mut buf[..want.min(1 << 20)])?;
                fout.write_all(&buf[..r])?;
                r
            };
            if n == 0 {
                break;
            }
            done += n as u64;
            self.bytes += n as u64;
            self.emit(false);
        }
        let _ = fout.set_permissions(meta.permissions());
        let times = fs::FileTimes::new().set_modified(meta.modified()?).set_accessed(meta.accessed()?);
        let _ = fout.set_times(times);
        Ok(())
    }

    /// Copies (or moves) src to exactly dst, asking when dst is taken. Ok(Some(final path)) when something landed.
    fn transfer(&mut self, src: &Path, dst: &Path, mv: bool) -> Result<Option<PathBuf>, Cancelled> {
        if self.cancelled() {
            return Err(Cancelled);
        }
        self.current = util::name_of(src);
        let Ok(lmeta) = fs::symlink_metadata(src) else {
            self.error(src, "missing");
            return Ok(None);
        };
        let mut dst = dst.to_path_buf();
        if let Ok(dmeta) = fs::symlink_metadata(&dst) {
            let same = dmeta.dev() == lmeta.dev() && dmeta.ino() == lmeta.ino();
            if same && mv {
                return Ok(None);
            }
            let both_dirs = lmeta.is_dir() && dmeta.is_dir();
            let answer = if same { "keep".to_string() } else { self.ask(src, &dst, both_dirs)? };
            match answer.as_str() {
                "skip" => {
                    self.files += 1;
                    if lmeta.is_file() {
                        self.bytes += lmeta.len();
                    }
                    return Ok(None);
                }
                "keep" => dst = util::free_name(dst.parent().unwrap_or(Path::new("/")), &util::name_of(&dst)),
                "replace" if both_dirs => return self.merge(src, &dst, mv).map(|_| Some(dst)),
                "merge" => return self.merge(src, &dst, mv).map(|_| Some(dst)),
                _ => {
                    // Replace: what was there goes to the trash, never straight out of existence.
                    if let Err(e) = trash::delete(&dst) {
                        if dmeta.is_dir() {
                            self.error(&dst, e);
                            return Ok(None);
                        }
                        if let Err(e) = fs::remove_file(&dst) {
                            self.error(&dst, error_code(&e));
                            return Ok(None);
                        }
                    }
                }
            }
        }
        if mv {
            match fs::rename(src, &dst) {
                Ok(()) => {
                    self.files += 1;
                    if lmeta.is_file() {
                        self.bytes += lmeta.len();
                    }
                    return Ok(Some(dst));
                }
                Err(e) if e.raw_os_error() == Some(libc::EXDEV) => {}
                Err(e) => {
                    self.error(src, error_code(&e));
                    return Ok(None);
                }
            }
        }
        let ft = lmeta.file_type();
        if ft.is_symlink() {
            let target = fs::read_link(src).unwrap_or_default();
            if let Err(e) = std::os::unix::fs::symlink(&target, &dst) {
                self.error(src, error_code(&e));
                return Ok(None);
            }
            self.files += 1;
        } else if ft.is_dir() {
            if let Err(e) = fs::create_dir(&dst) {
                self.error(&dst, error_code(&e));
                return Ok(None);
            }
            self.files += 1;
            self.merge_children(src, &dst, mv)?;
            let _ = fs::set_permissions(&dst, lmeta.permissions());
        } else if ft.is_file() {
            // Written beside the target and renamed over it at the end: a cancel or a crash never leaves half a file.
            let part = dst.with_file_name(format!(".{}.inir-part", util::name_of(&dst)));
            let _ = fs::remove_file(&part);
            match self.copy_data(src, &part) {
                Ok(()) => {
                    if let Err(e) = fs::rename(&part, &dst) {
                        let _ = fs::remove_file(&part);
                        self.error(&dst, error_code(&e));
                        return Ok(None);
                    }
                    self.files += 1;
                }
                Err(e) => {
                    let _ = fs::remove_file(&part);
                    if e.kind() == std::io::ErrorKind::Interrupted {
                        return Err(Cancelled);
                    }
                    self.error(src, error_code(&e));
                    return Ok(None);
                }
            }
        } else {
            self.error(src, "special");
            return Ok(None);
        }
        if mv {
            let removed = if ft.is_dir() { fs::remove_dir(src) } else { fs::remove_file(src) };
            if let Err(e) = removed {
                // A folder that kept files it could not move stays, with them in it.
                if !ft.is_dir() {
                    self.error(src, error_code(&e));
                }
            }
        }
        Ok(Some(dst))
    }

    fn merge(&mut self, src: &Path, dst: &Path, mv: bool) -> Result<(), Cancelled> {
        self.files += 1;
        self.merge_children(src, dst, mv)?;
        if mv {
            let _ = fs::remove_dir(src);
        }
        Ok(())
    }

    fn merge_children(&mut self, src: &Path, dst: &Path, mv: bool) -> Result<(), Cancelled> {
        let Ok(rd) = fs::read_dir(src) else {
            self.error(src, "denied");
            return Ok(());
        };
        let mut children: Vec<PathBuf> = rd.flatten().map(|d| d.path()).collect();
        children.sort();
        for child in children {
            let name = child.file_name().map(|n| n.to_os_string()).unwrap_or_default();
            self.transfer(&child, &dst.join(name), mv)?;
        }
        Ok(())
    }
}

fn paths(v: &Value) -> Vec<PathBuf> {
    v.as_array().into_iter().flatten().filter_map(|p| p.as_str()).filter(|p| !p.is_empty()).map(PathBuf::from).collect()
}

/// Starts a job and returns its id at once; progress and the result come as "job" events.
pub fn start(ctx: Arc<Ctx>, op: &str, req: &Value) -> Result<Value, String> {
    let sources = paths(&req["paths"]);
    let dest = req["dest"].as_str().unwrap_or("").to_string();
    let op = op.to_string();
    let req = req.clone();
    let (tx, rx) = mpsc::channel();
    std::thread::spawn(move || {
        let (id, mut run) = Run::new(&ctx, &op, &dest);
        let _ = tx.send(id);
        run.emit(true);
        match op.as_str() {
            "copy" | "move" | "duplicate" | "link" => transfer_job(&mut run, &op, &sources, Path::new(&dest)),
            "trash" => trash_job(&mut run, &sources),
            "delete" => delete_job(&mut run, &sources),
            "restore" => restore_job(&mut run, &sources),
            "untrash" => untrash_job(&mut run, &sources),
            "purge" => purge_job(&mut run, &sources),
            "emptytrash" => empty_job(&mut run),
            "extract" => extract_job(&mut run, &sources, Path::new(&dest), req["password"].as_str().unwrap_or("")),
            "compress" => compress_job(&mut run, &sources, Path::new(&dest)),
            "movepairs" => pairs_job(&mut run, &req["pairs"]),
            _ => run.error(Path::new(""), "unknown"),
        }
        run.finish();
    });
    let id = rx.recv().map_err(|e| e.to_string())?;
    Ok(json!({"job": id}))
}

fn transfer_job(run: &mut Run, op: &str, sources: &[PathBuf], dest: &Path) {
    let mv = op == "move";
    // A move inside one filesystem is a rename: nothing to count first.
    let dest_dev = fs::metadata(dest).map(|m| m.dev()).ok();
    let need_scan: Vec<PathBuf> = sources.iter().filter(|s| !mv || fs::symlink_metadata(s).map(|m| Some(m.dev()) != dest_dev).unwrap_or(true)).cloned().collect();
    run.scan(&need_scan);
    run.total_files += (sources.len() - need_scan.len()) as u64;
    run.state = "running";
    run.emit(true);
    for src in sources {
        if run.cancelled() {
            return;
        }
        let target_dir = if op == "duplicate" { src.parent().unwrap_or(Path::new("/")).to_path_buf() } else { dest.to_path_buf() };
        if !target_dir.is_dir() {
            run.error(&target_dir, "missing");
            continue;
        }
        // A folder into itself would never end.
        if fs::symlink_metadata(src).map(|m| m.is_dir()).unwrap_or(false) && target_dir.starts_with(src) {
            run.error(src, "intoitself");
            continue;
        }
        let name = util::name_of(src);
        let dst = if op == "duplicate" { util::free_name(&target_dir, &name) } else { target_dir.join(&name) };
        if op == "link" {
            let dst = util::free_name(&target_dir, &name);
            let target = fs::canonicalize(src).unwrap_or(src.clone());
            match std::os::unix::fs::symlink(&target, &dst) {
                Ok(()) => run.created.push(dst.to_string_lossy().into_owned()),
                Err(e) => run.error(src, error_code(&e)),
            }
            run.files += 1;
            continue;
        }
        match run.transfer(src, &dst, mv) {
            Ok(Some(landed)) => {
                if mv {
                    run.moved.push((src.to_string_lossy().into_owned(), landed.to_string_lossy().into_owned()));
                } else {
                    run.created.push(landed.to_string_lossy().into_owned());
                }
            }
            Ok(None) => {}
            Err(Cancelled) => return,
        }
    }
}

fn trash_job(run: &mut Run, sources: &[PathBuf]) {
    run.total_files = sources.len() as u64;
    run.state = "running";
    for src in sources {
        if run.cancelled() {
            return;
        }
        run.current = util::name_of(src);
        match trash::delete(src) {
            Ok(()) => run.trashed.push(src.to_string_lossy().into_owned()),
            Err(_) if fs::symlink_metadata(src).is_ok() => run.untrashable.push(src.to_string_lossy().into_owned()),
            Err(e) => run.error(src, e),
        }
        run.files += 1;
        run.emit(false);
    }
}

fn remove_tree(run: &mut Run, p: &Path) -> Result<(), Cancelled> {
    if run.cancelled() {
        return Err(Cancelled);
    }
    let Ok(m) = fs::symlink_metadata(p) else { return Ok(()) };
    if m.is_dir() {
        if let Ok(rd) = fs::read_dir(p) {
            for de in rd.flatten() {
                remove_tree(run, &de.path())?;
            }
        }
        if let Err(e) = fs::remove_dir(p) {
            run.error(p, error_code(&e));
        }
    } else {
        run.current = util::name_of(p);
        if let Err(e) = fs::remove_file(p) {
            run.error(p, error_code(&e));
        } else {
            run.bytes += m.len();
        }
    }
    run.files += 1;
    run.emit(false);
    Ok(())
}

fn delete_job(run: &mut Run, sources: &[PathBuf]) {
    run.scan(sources);
    run.total_bytes = 0;
    run.state = "running";
    for src in sources {
        if remove_tree(run, src).is_err() {
            return;
        }
    }
}

fn files_path(item: &trash::TrashItem) -> PathBuf {
    let info = PathBuf::from(&item.id);
    let name = info.file_name().map(|n| n.to_string_lossy().trim_end_matches(".trashinfo").to_string()).unwrap_or_default();
    info.parent().and_then(|p| p.parent()).map(|t| t.join("files").join(name)).unwrap_or_default()
}

pub fn trash_items() -> Vec<trash::TrashItem> {
    trash::os_limited::list().unwrap_or_default()
}

/// The trash as entries: each one's own file (to show it) with where it came from and when it left.
pub fn trash_list(ctx: &Ctx) -> Value {
    let items = trash_items();
    let mut out = Vec::new();
    for item in &items {
        let p = files_path(item);
        let Some(mut e) = crate::list::stat_many(ctx, &[p]).pop() else { continue };
        e["name"] = json!(item.name.to_string_lossy());
        e["origin"] = json!(item.original_path().to_string_lossy());
        e["deleted"] = json!(item.time_deleted * 1000);
        out.push(e);
    }
    out.sort_by(|a, b| b["deleted"].as_i64().cmp(&a["deleted"].as_i64()));
    json!({"entries": out})
}

fn restore_items(run: &mut Run, items: Vec<trash::TrashItem>) {
    run.total_files = items.len() as u64;
    run.state = "running";
    for item in items {
        if run.cancelled() {
            return;
        }
        run.current = item.name.to_string_lossy().into_owned();
        let origin = item.original_path();
        if fs::symlink_metadata(&origin).is_ok() {
            run.error(&origin, "exists");
        } else {
            if let Some(parent) = origin.parent() {
                let _ = fs::create_dir_all(parent);
            }
            match trash::os_limited::restore_all([item]) {
                Ok(()) => run.created.push(origin.to_string_lossy().into_owned()),
                Err(e) => run.error(&origin, e),
            }
        }
        run.files += 1;
        run.emit(false);
    }
}

fn restore_job(run: &mut Run, sources: &[PathBuf]) {
    let items: Vec<_> = trash_items().into_iter().filter(|i| sources.contains(&files_path(i))).collect();
    restore_items(run, items);
}

/// Undo of a trash: the latest trashed item for each original path comes back.
fn untrash_job(run: &mut Run, origins: &[PathBuf]) {
    let mut latest: HashMap<PathBuf, trash::TrashItem> = HashMap::new();
    for item in trash_items() {
        let o = item.original_path();
        if origins.contains(&o) && latest.get(&o).map(|l| item.time_deleted >= l.time_deleted).unwrap_or(true) {
            latest.insert(o, item);
        }
    }
    restore_items(run, latest.into_values().collect());
}

fn purge_job(run: &mut Run, sources: &[PathBuf]) {
    let items: Vec<_> = trash_items().into_iter().filter(|i| sources.contains(&files_path(i))).collect();
    run.total_files = items.len() as u64;
    run.state = "running";
    if let Err(e) = trash::os_limited::purge_all(items) {
        run.error(Path::new(""), e);
    }
    run.files = run.total_files;
}

fn empty_job(run: &mut Run) {
    let items = trash_items();
    run.total_files = items.len() as u64;
    run.state = "running";
    run.emit(true);
    if let Err(e) = trash::os_limited::purge_all(items) {
        run.error(Path::new(""), e);
    }
    run.files = run.total_files;
}

fn pairs_job(run: &mut Run, pairs: &Value) {
    let list: Vec<(PathBuf, PathBuf)> = pairs.as_array().into_iter().flatten()
        .filter_map(|p| Some((PathBuf::from(p.get(0)?.as_str()?), PathBuf::from(p.get(1)?.as_str()?)))).collect();
    run.total_files = list.len() as u64;
    run.state = "running";
    for (from, to) in list {
        if let Some(parent) = to.parent() {
            let _ = fs::create_dir_all(parent);
        }
        match run.transfer(&from, &to, true) {
            Ok(Some(landed)) => run.moved.push((from.to_string_lossy().into_owned(), landed.to_string_lossy().into_owned())),
            Ok(None) => {}
            Err(Cancelled) => return,
        }
    }
}

/// Runs a tool and counts the lines it reports on stderr (or stdout) as files done.
fn run_counted(run: &mut Run, mut cmd: std::process::Command, from_stdout: bool) -> Result<(), String> {
    use std::io::BufRead;
    use std::process::Stdio;
    cmd.stdin(Stdio::null());
    if from_stdout {
        cmd.stdout(Stdio::piped()).stderr(Stdio::piped());
    } else {
        cmd.stdout(Stdio::null()).stderr(Stdio::piped());
    }
    let mut child = cmd.spawn().map_err(|e| e.to_string())?;
    let stream: Box<dyn Read + Send> = if from_stdout { Box::new(child.stdout.take().unwrap()) } else { Box::new(child.stderr.take().unwrap()) };
    let err_tail = Arc::new(Mutex::new(String::new()));
    if from_stdout {
        let mut stderr = child.stderr.take().unwrap();
        let tail = err_tail.clone();
        std::thread::spawn(move || {
            let mut s = String::new();
            let _ = stderr.read_to_string(&mut s);
            *tail.lock().unwrap() = s;
        });
    }
    let (tx, rx) = mpsc::channel::<String>();
    std::thread::spawn(move || {
        for line in std::io::BufReader::new(stream).lines().map_while(Result::ok) {
            if tx.send(line).is_err() {
                break;
            }
        }
    });
    let mut last_lines: Vec<String> = Vec::new();
    loop {
        if run.cancelled() {
            let _ = child.kill();
            let _ = child.wait();
            return Err("cancelled".into());
        }
        match rx.recv_timeout(std::time::Duration::from_millis(100)) {
            Ok(line) => {
                let name = line.trim().trim_start_matches("x ").trim_start_matches("a ").trim_start_matches("- ").to_string();
                if !name.is_empty() {
                    run.current = name.rsplit('/').find(|s| !s.is_empty()).unwrap_or(&name).to_string();
                    run.files += 1;
                }
                last_lines.push(line);
                if last_lines.len() > 8 {
                    last_lines.remove(0);
                }
                run.emit(false);
            }
            Err(mpsc::RecvTimeoutError::Timeout) => {
                if let Ok(Some(_)) = child.try_wait() {
                    // Drain what is left.
                    while let Ok(line) = rx.recv_timeout(std::time::Duration::from_millis(50)) {
                        last_lines.push(line);
                    }
                    break;
                }
                run.emit(false);
            }
            Err(_) => break,
        }
    }
    let status = child.wait().map_err(|e| e.to_string())?;
    if status.success() {
        Ok(())
    } else {
        let mut text = last_lines.join("\n");
        text.push_str(&err_tail.lock().unwrap());
        Err(text)
    }
}

fn extract_job(run: &mut Run, archives: &[PathBuf], dest: &Path, password: &str) {
    run.state = "running";
    for archive in archives {
        if run.cancelled() {
            return;
        }
        let name = util::name_of(archive);
        let base = util::split_ext(&name).0.to_string();
        let target = if dest.as_os_str().is_empty() { archive.parent().unwrap_or(Path::new("/")).to_path_buf() } else { dest.to_path_buf() };
        let tmp = util::free_name(&target, &format!(".{base}.inir-extract"));
        if let Err(e) = fs::create_dir_all(&tmp) {
            run.error(archive, error_code(&e));
            continue;
        }
        let mut cmd = std::process::Command::new("bsdtar");
        cmd.arg("-xvf").arg(archive).arg("-C").arg(&tmp);
        if !password.is_empty() {
            cmd.arg("--passphrase").arg(password);
        }
        let mut result = run_counted(run, cmd, false);
        if result.is_err() && !run.cancelled() && util::which("7z").is_some() {
            // libarchive leaves some 7z filters and RAR5 features to 7-Zip.
            let _ = fs::remove_dir_all(&tmp);
            let _ = fs::create_dir_all(&tmp);
            let mut cmd = std::process::Command::new("7z");
            cmd.arg("x").arg("-y").arg("-bb1").arg(format!("-p{password}")).arg(format!("-o{}", tmp.to_string_lossy())).arg(archive);
            result = run_counted(run, cmd, true);
        }
        match result {
            Ok(()) => {
                // One folder inside comes out as itself; loose files get a folder named after the archive.
                let inner: Vec<PathBuf> = fs::read_dir(&tmp).map(|rd| rd.flatten().map(|d| d.path()).collect()).unwrap_or_default();
                let landed = if inner.len() == 1 {
                    let out = util::free_name(&target, &util::name_of(&inner[0]));
                    let r = fs::rename(&inner[0], &out);
                    let _ = fs::remove_dir(&tmp);
                    r.map(|_| out)
                } else {
                    let out = util::free_name(&target, &base);
                    fs::rename(&tmp, &out).map(|_| out)
                };
                match landed {
                    Ok(p) => run.created.push(p.to_string_lossy().into_owned()),
                    Err(e) => run.error(archive, error_code(&e)),
                }
            }
            Err(e) => {
                let _ = fs::remove_dir_all(&tmp);
                let lower = e.to_lowercase();
                let code = if lower.contains("passphrase") || lower.contains("password") || lower.contains("encrypted") { "password" } else if e == "cancelled" { return } else { "corrupt" };
                run.errors.push(json!({"path": archive.to_string_lossy(), "error": code, "detail": e.chars().take(400).collect::<String>()}));
            }
        }
    }
}

fn compress_job(run: &mut Run, sources: &[PathBuf], dest: &Path) {
    let Some(first) = sources.first() else { return };
    let parent = first.parent().unwrap_or(Path::new("/")).to_path_buf();
    run.scan(sources);
    run.total_bytes = 0;
    run.state = "running";
    let name = util::name_of(dest);
    let dir = dest.parent().unwrap_or(&parent).to_path_buf();
    let final_path = util::free_name(&dir, &name);
    let part = dir.join(format!(".inir-part-{}", util::name_of(&final_path)));
    let _ = fs::remove_file(&part);
    let lower = name.to_lowercase();
    let rel: Vec<String> = sources.iter().map(|s| util::name_of(s)).collect();
    let result = if lower.ends_with(".7z") {
        let mut cmd = std::process::Command::new("7z");
        cmd.current_dir(&parent).arg("a").arg("-bb1").arg("-y").arg(&part).args(&rel);
        run_counted(run, cmd, true)
    } else {
        let mut cmd = std::process::Command::new("bsdtar");
        cmd.arg("-a").arg("-cvf").arg(&part).arg("-C").arg(&parent).args(&rel);
        if lower.ends_with(".zip") {
            cmd.arg("--options").arg("zip:compression=deflate");
        }
        run_counted(run, cmd, false)
    };
    match result {
        Ok(()) => match fs::rename(&part, &final_path) {
            Ok(()) => run.created.push(final_path.to_string_lossy().into_owned()),
            Err(e) => run.error(&final_path, error_code(&e)),
        },
        Err(e) => {
            let _ = fs::remove_file(&part);
            if e != "cancelled" {
                run.errors.push(json!({"path": final_path.to_string_lossy(), "error": "failed", "detail": e.chars().take(400).collect::<String>()}));
            }
        }
    }
}

// Quick changes that answer at once.

pub fn rename(req: &Value) -> Result<Value, String> {
    let from = PathBuf::from(req["path"].as_str().unwrap_or(""));
    let name = req["name"].as_str().unwrap_or("").trim();
    if name.is_empty() || name.contains('/') || name == "." || name == ".." {
        return Err("badname".into());
    }
    let to = from.with_file_name(name);
    if to == from {
        return Ok(json!({"from": from.to_string_lossy(), "to": to.to_string_lossy()}));
    }
    // Only a change of case may reuse the name (case-insensitive filesystems report the old one as taken).
    if fs::symlink_metadata(&to).is_ok() && util::name_of(&from).to_lowercase() != name.to_lowercase() {
        return Err("exists".into());
    }
    fs::rename(&from, &to).map_err(|e| error_code(&e))?;
    Ok(json!({"from": from.to_string_lossy(), "to": to.to_string_lossy()}))
}

/// Many renames at once, safe against swaps (a→b, b→a): every file steps through a temporary name first.
pub fn batch_rename(req: &Value) -> Result<Value, String> {
    let items: Vec<(PathBuf, String)> = req["items"].as_array().into_iter().flatten()
        .filter_map(|i| Some((PathBuf::from(i["path"].as_str()?), i["name"].as_str()?.trim().to_string()))).collect();
    let mut names = std::collections::HashSet::new();
    for (p, n) in &items {
        if n.is_empty() || n.contains('/') {
            return Err("badname".into());
        }
        if !names.insert(p.with_file_name(n)) {
            return Err("duplicate".into());
        }
    }
    let moving: std::collections::HashSet<PathBuf> = items.iter().map(|(p, _)| p.clone()).collect();
    for (p, n) in &items {
        let to = p.with_file_name(n);
        if &to != p && fs::symlink_metadata(&to).is_ok() && !moving.contains(&to) {
            return Err(format!("exists:{n}"));
        }
    }
    let mut staged = Vec::new();
    for (i, (p, n)) in items.iter().enumerate() {
        let tmp = p.with_file_name(format!(".inir-rename-{}-{i}", std::process::id()));
        if let Err(e) = fs::rename(p, &tmp) {
            // Put back what already moved.
            for (orig, t, _) in staged.iter().rev() {
                let _ = fs::rename(t, orig);
            }
            return Err(error_code(&e));
        }
        staged.push((p.clone(), tmp, n.clone()));
    }
    let mut pairs = Vec::new();
    for (orig, tmp, n) in staged {
        let to = orig.with_file_name(&n);
        let _ = fs::rename(&tmp, &to);
        pairs.push(json!([orig.to_string_lossy(), to.to_string_lossy()]));
    }
    Ok(json!({"pairs": pairs}))
}

pub fn mkdir(req: &Value) -> Result<Value, String> {
    let dir = PathBuf::from(req["dir"].as_str().unwrap_or(""));
    let name = req["name"].as_str().unwrap_or("New folder");
    let path = util::free_name(&dir, name);
    fs::create_dir(&path).map_err(|e| error_code(&e))?;
    Ok(json!({"path": path.to_string_lossy()}))
}

pub fn newfile(req: &Value) -> Result<Value, String> {
    let dir = PathBuf::from(req["dir"].as_str().unwrap_or(""));
    let template = req["template"].as_str().unwrap_or("");
    let name = if template.is_empty() { req["name"].as_str().unwrap_or("New document").to_string() } else { util::name_of(Path::new(template)) };
    let path = util::free_name(&dir, &name);
    if template.is_empty() {
        fs::OpenOptions::new().write(true).create_new(true).open(&path).map_err(|e| error_code(&e))?;
    } else {
        fs::copy(template, &path).map_err(|e| error_code(&e))?;
    }
    Ok(json!({"path": path.to_string_lossy()}))
}

pub fn chmod(req: &Value) -> Result<Value, String> {
    let path = PathBuf::from(req["path"].as_str().unwrap_or(""));
    let mode = req["mode"].as_u64().ok_or("badmode")? as u32;
    fs::set_permissions(&path, fs::Permissions::from_mode(mode & 0o7777)).map_err(|e| error_code(&e))?;
    Ok(json!({"mode": mode & 0o7777}))
}

pub fn templates() -> Value {
    let dir = crate::places::xdg_dirs().into_iter().find(|(r, _)| *r == "templates").map(|(_, p)| p);
    let mut out: Vec<Value> = dir.and_then(|d| fs::read_dir(d).ok()).map(|rd| rd.flatten().filter(|e| e.path().is_file())
        .map(|e| json!({"path": e.path().to_string_lossy(), "name": util::split_ext(&e.file_name().to_string_lossy()).0.to_string()})).collect()).unwrap_or_default();
    out.sort_by(|a, b| util::natural_cmp(a["name"].as_str().unwrap_or(""), b["name"].as_str().unwrap_or("")));
    json!({"templates": out})
}
