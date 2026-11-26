// Administrator mode ("Open as Administrator"): spawns a single elevated copy of this very binary
// (`pkexec <exe> --admin-helper`) communicating strictly over its inherited stdin/stdout JSONL pipe.
// The QML GUI never runs as root; Polkit handles authentication natively on Wayland, and the helper
// exits automatically when closed, when the parent exits (EOF), or after 15 minutes of inactivity.

use crate::Ctx;
use serde_json::{json, Value};
use std::collections::HashMap;
use std::io::{BufRead, BufReader, Write};
use std::path::PathBuf;
use std::process::{Child, ChildStdin, Command, Stdio};
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::{mpsc, Arc, Mutex};
use std::time::{Duration, Instant};

pub const ADMIN_JOB_BASE: u64 = 1_000_000;
const IDLE_TIMEOUT_SECS: u64 = 15 * 60;

/// Ops allowed to run inside the elevated helper.
pub fn is_admin_op(op: &str) -> bool {
    matches!(
        op,
        "ping"
            | "list"
            | "stat"
            | "info"
            | "text"
            | "markdown"
            | "rename"
            | "batch_rename"
            | "mkdir"
            | "newfile"
            | "chmod"
            | "copy"
            | "move"
            | "duplicate"
            | "link"
            | "delete"
            | "extract"
            | "compress"
            | "movepairs"
            | "job_cancel"
            | "job_answer"
    )
}

struct Session {
    stdin: ChildStdin,
    child: Child,
}

#[derive(Default)]
pub struct Admin {
    session: Mutex<Option<Session>>,
    next_id: AtomicU64,
    pending: Arc<Mutex<HashMap<u64, mpsc::Sender<Value>>>>,
    starting: Mutex<()>,
}

impl Admin {
    pub fn active(&self) -> bool {
        self.session.lock().unwrap().is_some()
    }

    pub fn start(&self, ctx: &Arc<Ctx>) -> Result<Value, String> {
        let _start_guard = self.starting.lock().unwrap();
        if self.active() {
            return Ok(json!({"active": true}));
        }
        let pkexec = crate::util::which("pkexec").ok_or_else(|| "nopkexec".to_string())?;
        let exe = std::env::current_exe().map_err(|_| "admin_failed".to_string())?;

        let mut child = Command::new(pkexec)
            .arg(&exe)
            .arg("--admin-helper")
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .stderr(Stdio::null())
            .spawn()
            .map_err(|_| "admin_failed".to_string())?;

        let stdin = child.stdin.take().ok_or_else(|| "admin_failed".to_string())?;
        let stdout = child.stdout.take().ok_or_else(|| "admin_failed".to_string())?;
        let mut reader = BufReader::new(stdout);

        // Wait for the helper's first line confirming Polkit authentication succeeded.
        let mut first = String::new();
        let ready = match reader.read_line(&mut first) {
            Ok(n) if n > 0 => serde_json::from_str::<Value>(&first)
                .ok()
                .and_then(|v| v["event"].as_str().map(|s| s == "admin_ready"))
                .unwrap_or(false),
            _ => false,
        };
        if !ready {
            drop(stdin);
            let code = child.wait().ok().and_then(|s| s.code()).unwrap_or(1);
            // pkexec exits 126 when the user dismisses auth, 127 when not authorized / not found.
            return Err(if code == 126 || code == 127 { "admin_cancelled" } else { "admin_failed" }.into());
        }

        *self.session.lock().unwrap() = Some(Session { stdin, child });

        let ctx_bg = ctx.clone();
        let pending = self.pending.clone();
        std::thread::spawn(move || {
            for line in reader.lines() {
                let Ok(line) = line else { break };
                let Ok(val) = serde_json::from_str::<Value>(&line) else { continue };
                if let Some(id) = val["id"].as_u64() {
                    if let Some(tx) = pending.lock().unwrap().remove(&id) {
                        let _ = tx.send(val);
                    }
                } else if val["event"].is_string() {
                    ctx_bg.out.send(&val);
                }
            }
            // Helper exited (user stopped it, timed out, or died): wake any pending waiters.
            {
                let mut guard = ctx_bg.admin.session.lock().unwrap();
                if let Some(mut s) = guard.take() {
                    let _ = s.child.wait();
                }
            }
            let waiters: Vec<_> = pending.lock().unwrap().drain().collect();
            for (_, tx) in waiters {
                let _ = tx.send(json!({"ok": false, "error": "admin_inactive"}));
            }
            ctx_bg.out.event("admin", json!({"active": false}));
        });

        ctx.out.event("admin", json!({"active": true}));
        Ok(json!({"active": true}))
    }

    pub fn stop(&self, ctx: &Ctx) -> Result<Value, String> {
        let taken = self.session.lock().unwrap().take();
        if let Some(mut s) = taken {
            // Closing stdin tells the helper to exit cleanly.
            drop(s.stdin);
            let _ = s.child.kill();
            let _ = s.child.wait();
            ctx.out.event("admin", json!({"active": false}));
        }
        Ok(json!({"active": false}))
    }

    pub fn call(&self, mut req: Value) -> Result<Value, String> {
        let op = req["op"].as_str().unwrap_or("");
        if !is_admin_op(op) {
            return Err("unknownop".into());
        }
        let internal_id = self.next_id.fetch_add(1, Ordering::Relaxed) + 1;
        if let Value::Object(m) = &mut req {
            m.insert("id".into(), json!(internal_id));
            m.remove("admin");
        }
        let line = format!("{req}\n");
        let (tx, rx) = mpsc::channel();
        self.pending.lock().unwrap().insert(internal_id, tx);

        let write_res = {
            let mut guard = self.session.lock().unwrap();
            match guard.as_mut() {
                Some(s) => s.stdin.write_all(line.as_bytes()).and_then(|_| s.stdin.flush()),
                None => {
                    self.pending.lock().unwrap().remove(&internal_id);
                    return Err("admin_inactive".into());
                }
            }
        };
        if write_res.is_err() {
            self.pending.lock().unwrap().remove(&internal_id);
            return Err("admin_inactive".into());
        }

        let mut reply = rx.recv().map_err(|_| "admin_inactive".to_string())?;
        if reply["ok"].as_bool() == Some(true) {
            if let Value::Object(m) = &mut reply {
                m.remove("id");
                m.remove("ok");
            }
            Ok(reply)
        } else {
            Err(reply["error"].as_str().unwrap_or("admin_failed").to_string())
        }
    }
}

/// Entry point when invoked as `pkexec <exe> --admin-helper`.
/// Runs a minimal JSONL file-operations server over stdin/stdout with an idle watchdog.
pub fn run_helper() {
    let ctx = Arc::new(Ctx {
        out: crate::Out,
        mime: crate::mime::MimeDb::load(),
        thumbs: crate::thumbs::Thumbs::new(),
        jobs: crate::jobs::Registry::with_base(ADMIN_JOB_BASE),
        watch: crate::watch::Watch::default(),
        talks: crate::remote::Talks::default(),
        portal: crate::portal::Registry::default(),
        admin: Admin::default(),
        localsend: crate::localsend::LocalSend::default(),
        cancels: Mutex::new(HashMap::new()),
    });

    let last_activity = Arc::new(Mutex::new(Instant::now()));
    {
        let last = last_activity.clone();
        let ctx_w = ctx.clone();
        std::thread::spawn(move || loop {
            std::thread::sleep(Duration::from_secs(30));
            if ctx_w.jobs.active() > 0 {
                *last.lock().unwrap() = Instant::now();
                continue;
            }
            if last.lock().unwrap().elapsed() >= Duration::from_secs(IDLE_TIMEOUT_SECS) {
                std::process::exit(0);
            }
        });
    }

    ctx.out.event("admin_ready", json!({"uid": unsafe { libc::geteuid() }}));

    let in_flight = Arc::new(std::sync::atomic::AtomicUsize::new(0));
    for line in std::io::stdin().lock().lines() {
        let Ok(line) = line else { break };
        if line.trim().is_empty() {
            continue;
        }
        *last_activity.lock().unwrap() = Instant::now();
        let Ok(req) = serde_json::from_str::<Value>(&line) else {
            ctx.out.event("error", json!({"error": "badjson"}));
            continue;
        };
        let ctx = ctx.clone();
        let counter = in_flight.clone();
        counter.fetch_add(1, Ordering::SeqCst);
        std::thread::spawn(move || {
            handle_admin(&ctx, req);
            counter.fetch_sub(1, Ordering::SeqCst);
        });
    }

    while in_flight.load(Ordering::SeqCst) > 0 || ctx.jobs.active() > 0 {
        std::thread::sleep(Duration::from_millis(20));
    }
}

fn paths(v: &Value) -> Vec<PathBuf> {
    v.as_array().into_iter().flatten().filter_map(|p| p.as_str()).map(PathBuf::from).collect()
}

fn handle_admin(ctx: &Arc<Ctx>, req: Value) {
    let id = req["id"].clone();
    let op = req["op"].as_str().unwrap_or("");
    let path = PathBuf::from(req["path"].as_str().unwrap_or(""));
    let res: Result<Value, String> = match op {
        "ping" => Ok(json!({"uid": unsafe { libc::geteuid() }})),
        "list" => match crate::list::list(ctx, &req) {
            Ok((v, _)) => Ok(v),
            Err(e) => Err(e),
        },
        "stat" => Ok(json!({"entries": crate::list::stat_many(ctx, &paths(&req["paths"]))})),
        "info" => crate::info::info(ctx, &path),
        "text" => Ok(crate::info::text_head(&path, req["limit"].as_u64().unwrap_or(262144) as usize)),
        "markdown" => crate::markdown::markdown(&req),
        "rename" => crate::jobs::rename(&req),
        "batch_rename" => crate::jobs::batch_rename(&req),
        "mkdir" => crate::jobs::mkdir(&req),
        "newfile" => crate::jobs::newfile(&req),
        "chmod" => crate::jobs::chmod(&req),
        "copy" | "move" | "duplicate" | "link" | "delete" | "extract" | "compress" | "movepairs" => {
            crate::jobs::start(ctx.clone(), op, &req)
        }
        "job_cancel" => {
            ctx.jobs.cancel(req["job"].as_u64().unwrap_or(0));
            Ok(json!({}))
        }
        "job_answer" => {
            ctx.jobs.resolve(
                req["job"].as_u64().unwrap_or(0),
                req["action"].as_str().unwrap_or("skip").to_string(),
                req["all"].as_bool().unwrap_or(false),
            );
            Ok(json!({}))
        }
        _ => Err("unknownop".into()),
    };
    let v = match res {
        Ok(Value::Object(mut m)) => {
            m.insert("id".into(), id);
            m.insert("ok".into(), json!(true));
            Value::Object(m)
        }
        Ok(other) => json!({"id": id, "ok": true, "value": other}),
        Err(e) => json!({"id": id, "ok": false, "error": e}),
    };
    ctx.out.send(&v);
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn admin_ops_are_strictly_scoped() {
        assert!(is_admin_op("list"));
        assert!(is_admin_op("mkdir"));
        assert!(is_admin_op("copy"));
        assert!(is_admin_op("delete"));
        assert!(is_admin_op("chmod"));
        assert!(!is_admin_op("run"));
        assert!(!is_admin_op("terminal"));
        assert!(!is_admin_op("open"));
        assert!(!is_admin_op("portal_set"));
    }

    #[test]
    fn inactive_session_returns_error() {
        let admin = Admin::default();
        assert!(!admin.active());
        let err = admin.call(json!({"op": "list", "path": "/"})).unwrap_err();
        assert_eq!(err, "admin_inactive");
    }
}
