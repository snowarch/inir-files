// inir-files-core: the file manager's work off the interface thread. One JSON object per line on stdin is a request
// ({"id": 1, "op": "list", ...}); each gets one reply line ({"id": 1, "ok": true, ...} or {"id": 1, "ok": false,
// "error": "denied"}). Work that streams (thumbnails, jobs, searches, sizes, folder changes) arrives as events
// ({"event": "thumb", ...}). The process ends when the interface closes stdin, after the jobs at work have finished.

mod admin;
mod apps;
mod fm1;
mod info;
mod jobs;
mod list;
mod markdown;
mod mime;
mod places;
mod portal;
mod remote;
mod search;
mod thumbs;
mod util;
mod watch;

use serde_json::{json, Value};
use std::collections::HashMap;
use std::io::{BufRead, Write};
use std::path::PathBuf;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex};

pub struct Out;

impl Out {
    pub fn send(&self, v: &Value) {
        let mut line = v.to_string();
        line.push('\n');
        let mut o = std::io::stdout().lock();
        if o.write_all(line.as_bytes()).and_then(|_| o.flush()).is_err() {
            // Nobody reads any more: the interface is gone.
            std::process::exit(0);
        }
    }

    pub fn event(&self, name: &str, mut v: Value) {
        if let Value::Object(m) = &mut v {
            m.insert("event".into(), json!(name));
        }
        self.send(&v);
    }
}

pub struct Ctx {
    pub out: Out,
    pub mime: mime::MimeDb,
    pub thumbs: thumbs::Thumbs,
    pub jobs: jobs::Registry,
    pub watch: watch::Watch,
    pub talks: remote::Talks,
    pub portal: portal::Registry,
    pub admin: admin::Admin,
    cancels: Mutex<HashMap<String, Arc<AtomicBool>>>,
}

impl Ctx {
    /// A stop flag for a token; a new search or count under the same token stops the old one.
    pub fn token(&self, token: &str) -> Arc<AtomicBool> {
        let flag = Arc::new(AtomicBool::new(false));
        if let Some(old) = self.cancels.lock().unwrap().insert(token.to_string(), flag.clone()) {
            old.store(true, Ordering::Relaxed);
        }
        flag
    }

    pub fn cancel(&self, token: &str) {
        if let Some(f) = self.cancels.lock().unwrap().get(token) {
            f.store(true, Ordering::Relaxed);
        }
    }

    pub fn release(&self, token: &str, flag: &Arc<AtomicBool>) {
        let mut map = self.cancels.lock().unwrap();
        if map.get(token).map(|f| Arc::ptr_eq(f, flag)).unwrap_or(false) {
            map.remove(token);
        }
    }
}

fn paths(v: &Value) -> Vec<PathBuf> {
    v.as_array().into_iter().flatten().filter_map(|p| p.as_str()).map(PathBuf::from).collect()
}

fn reply(ctx: &Ctx, id: &Value, res: Result<Value, String>) {
    let v = match res {
        Ok(Value::Object(mut m)) => {
            m.insert("id".into(), id.clone());
            m.insert("ok".into(), json!(true));
            Value::Object(m)
        }
        Ok(other) => json!({"id": id, "ok": true, "value": other}),
        Err(e) => json!({"id": id, "ok": false, "error": e}),
    };
    ctx.out.send(&v);
}

fn streamed(ctx: &Arc<Ctx>, op: &str, req: &Value) {
    let token = req["token"].as_str().unwrap_or(op).to_string();
    let flag = ctx.token(&token);
    match op {
        "search" => search::search(ctx, req, flag.clone()),
        "dirsize" => info::dirsize(ctx, &token, paths(&req["paths"]), flag.clone()),
        "space_map" => info::space_map(ctx, &token, PathBuf::from(req["path"].as_str().unwrap_or("")), flag.clone()),
        "checksum" => info::checksum(ctx, &token, &PathBuf::from(req["path"].as_str().unwrap_or("")), req["algo"].as_str().unwrap_or("sha256"), flag.clone()),
        _ => {}
    }
    ctx.release(&token, &flag);
}

fn handle(ctx: &Arc<Ctx>, req: Value) {
    let id = req["id"].clone();
    let op = req["op"].as_str().unwrap_or("").to_string();
    let path = PathBuf::from(req["path"].as_str().unwrap_or(""));
    if req["admin"].as_bool() == Some(true) && admin::is_admin_op(&op) {
        let res = ctx.admin.call(req);
        reply(ctx, &id, res);
        return;
    }
    let res: Result<Value, String> = match op.as_str() {
        "admin_start" => ctx.admin.start(ctx),
        "admin_stop" => ctx.admin.stop(ctx),
        "admin_status" => Ok(json!({"active": ctx.admin.active()})),
        "ping" => Ok(json!({})),
        "list" => match list::list(ctx, &req) {
            Ok((v, counts)) => {
                reply(ctx, &id, Ok(v));
                if let Some(c) = counts {
                    c.spawn(ctx);
                }
                return;
            }
            Err(e) => Err(e),
        },
        "stat" => Ok(json!({"entries": list::stat_many(ctx, &paths(&req["paths"]))})),
        "info" => info::info(ctx, &path),
        "text" => Ok(info::text_head(&path, req["limit"].as_u64().unwrap_or(262144) as usize)),
        "markdown" => markdown::markdown(&req),
        "thumb" => {
            let size = req["size"].as_str().unwrap_or("large").to_string();
            let mut list = paths(&req["paths"]);
            if list.is_empty() && !path.as_os_str().is_empty() {
                list.push(path.clone());
            }
            let ahead = req["ahead"].as_bool().unwrap_or(false);
            let replace_ahead = req["replaceAhead"].as_bool().unwrap_or(false);
            ctx.thumbs.request(list, &size, ahead, replace_ahead);
            Ok(json!({}))
        }
        // Slow (a PDF page takes a moment): drawn on its own thread, the answer comes when it is ready.
        "render" => {
            let (ctx, id) = (ctx.clone(), id.clone());
            let page = req["page"].as_u64().unwrap_or(0) as u32;
            let side = req["side"].as_u64().unwrap_or(1600) as u32;
            std::thread::spawn(move || {
                let res = thumbs::render(&ctx, &path, page, side);
                reply(&ctx, &id, res);
            });
            return;
        }
        "thumbs_clear" => {
            ctx.thumbs.clear();
            Ok(json!({}))
        }
        "search" | "dirsize" | "space_map" | "checksum" => {
            reply(ctx, &id, Ok(json!({})));
            streamed(ctx, &op, &req);
            return;
        }
        "cancel" => {
            if let Some(f) = ctx.cancels.lock().unwrap().get(req["token"].as_str().unwrap_or("")) {
                f.store(true, Ordering::Relaxed);
            }
            Ok(json!({}))
        }
        "copy" | "move" | "duplicate" | "link" | "trash" | "delete" | "restore" | "untrash" | "purge" | "emptytrash" | "extract" | "compress" | "movepairs" => jobs::start(ctx.clone(), &op, &req),
        "job_cancel" => {
            let jid = req["job"].as_u64().unwrap_or(0);
            if jid >= admin::ADMIN_JOB_BASE {
                let _ = ctx.admin.call(req);
            } else {
                ctx.jobs.cancel(jid);
            }
            Ok(json!({}))
        }
        "job_answer" => {
            let jid = req["job"].as_u64().unwrap_or(0);
            if jid >= admin::ADMIN_JOB_BASE {
                let _ = ctx.admin.call(req);
            } else {
                ctx.jobs.resolve(jid, req["action"].as_str().unwrap_or("skip").to_string(), req["all"].as_bool().unwrap_or(false));
            }
            Ok(json!({}))
        }
        "trash_list" => Ok(jobs::trash_list(ctx)),
        "samefs" => {
            // A drop moves within one disk and copies across two, as people expect from every file manager.
            use std::os::unix::fs::MetadataExt;
            let dest = std::fs::metadata(req["dest"].as_str().unwrap_or("")).map(|m| m.dev()).ok();
            let same = dest.is_some() && paths(&req["paths"]).iter().all(|p| std::fs::symlink_metadata(p).map(|m| Some(m.dev()) == dest).unwrap_or(false));
            Ok(json!({"same": same}))
        }
        "rename" => jobs::rename(&req),
        "batch_rename" => jobs::batch_rename(&req),
        "mkdir" => jobs::mkdir(&req),
        "newfile" => jobs::newfile(&req),
        "chmod" => jobs::chmod(&req),
        "templates" => Ok(jobs::templates()),
        "places" => Ok(places::places()),
        "bookmark_add" | "bookmark_remove" | "bookmark_rename" | "bookmark_move" => places::bookmark_op(&op, &req),
        "mount" => places::mount(&req),
        "unmount" => places::unmount(&req),
        // A server: waits for gio and for the person's answers on this request's own thread.
        "connect" => remote::connect(ctx, &req),
        "connect_answer" => remote::answer(ctx, &req),
        "recent" => Ok(places::recent(ctx)),
        "watch" => Ok(watch::set(ctx, &req)),
        "apps" => Ok(apps::apps_op(ctx, &req)),
        "all_apps" => Ok(apps::all_apps_op()),
        "open" => apps::open(ctx, &req),
        "set_default" => apps::set_default(&req),
        "default_fm_get" => apps::default_fm_get(),
        "default_fm_set" => apps::default_fm_set(&req),
        "portal_get" => portal::portal_get(),
        "portal_set" => portal::portal_set(&req),
        "chooser_reply" => ctx.portal.answer(&req),
        "terminal" => apps::terminal(&req),
        "run" => apps::run(&req),
        "wallpaper" => apps::wallpaper(&req),
        "clip_set" => apps::clip_set(&req),
        "clip_get" => apps::clip_get(),
        "clip_save" => apps::clip_save(&req),
        _ => Err("unknownop".into()),
    };
    reply(ctx, &id, res);
}

fn main() {
    if std::env::args().any(|a| a == "--admin-helper") {
        admin::run_helper();
        return;
    }
    let ctx = Arc::new(Ctx {
        out: Out,
        mime: mime::MimeDb::load(),
        thumbs: thumbs::Thumbs::new(),
        jobs: jobs::Registry::default(),
        watch: watch::Watch::default(),
        talks: remote::Talks::default(),
        portal: portal::Registry::default(),
        admin: admin::Admin::default(),
        cancels: Mutex::new(HashMap::new()),
    });
    thumbs::start(ctx.clone());
    watch::start(ctx.clone());
    ctx.out.event("ready", json!({"version": env!("CARGO_PKG_VERSION"), "pid": std::process::id(), "home": util::home().to_string_lossy()}));
    fm1::start(ctx.clone());
    portal::start(ctx.clone());
    for line in std::io::stdin().lock().lines() {
        let Ok(line) = line else { break };
        if line.trim().is_empty() {
            continue;
        }
        match serde_json::from_str::<Value>(&line) {
            Ok(req) => {
                // Fast lock-only ops run inline on the stdin loop to avoid spawning thousands of short-lived threads.
                let is_admin = req["admin"].as_bool() == Some(true) || req["job"].as_u64().unwrap_or(0) >= admin::ADMIN_JOB_BASE;
                let fast = !is_admin && matches!(
                    req["op"].as_str().unwrap_or(""),
                    "ping" | "thumb" | "thumbs_clear" | "cancel" | "job_cancel" | "job_answer" | "chooser_reply" | "admin_status"
                );
                if fast {
                    handle(&ctx, req);
                } else {
                    let ctx = ctx.clone();
                    std::thread::spawn(move || handle(&ctx, req));
                }
            }
            Err(_) => ctx.out.event("error", json!({"error": "badjson"})),
        }
    }
    // The window closed: a copy or portal D-Bus reply at work still finishes whole.
    let mut waited = 0;
    while ctx.jobs.active() > 0 || (ctx.portal.active() > 0 && waited < 25) {
        std::thread::sleep(std::time::Duration::from_millis(100));
        waited += 1;
    }
    // Brief flush window so any just-sent D-Bus reply leaves the socket before exit.
    std::thread::sleep(std::time::Duration::from_millis(80));
}
