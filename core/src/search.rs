// Search below a folder, streamed as it goes: by name (every word must appear, accents and case aside, or a glob such
// as *.png), or by content through ripgrep with the first matching line shown. Best matches first within each batch.

use crate::util;
use crate::Ctx;
use serde_json::{json, Value};
use std::collections::HashSet;
use std::fs;
use std::path::PathBuf;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::Arc;
use std::time::Instant;

const SKIP: &[&str] = &["/proc", "/sys", "/dev", "/run", "/tmp/.X11-unix"];

fn score(name: &str, terms: &[String], glob: Option<&[char]>) -> Option<u32> {
    let folded = util::fold(name);
    if let Some(g) = glob {
        let chars: Vec<char> = folded.chars().collect();
        return glob_match(g, &chars).then_some(10);
    }
    let mut s = 0;
    for t in terms {
        let at = folded.find(t.as_str())?;
        s += if at == 0 { 0 } else if folded[..at].ends_with([' ', '-', '_', '.']) { 1 } else { 3 };
    }
    if folded == terms.join(" ") {
        return Some(0);
    }
    Some(s + 1)
}

fn glob_match(p: &[char], n: &[char]) -> bool {
    match (p.first(), n.first()) {
        (None, None) => true,
        (Some('*'), _) => glob_match(&p[1..], n) || (!n.is_empty() && glob_match(p, &n[1..])),
        (Some('?'), Some(_)) => glob_match(&p[1..], &n[1..]),
        (Some(a), Some(b)) => a == b && glob_match(&p[1..], &n[1..]),
        _ => false,
    }
}

pub fn search(ctx: &Ctx, req: &Value, stop: Arc<AtomicBool>) {
    let token = req["token"].as_str().unwrap_or("").to_string();
    let root = PathBuf::from(req["root"].as_str().unwrap_or("/"));
    let query = req["query"].as_str().unwrap_or("").trim().to_string();
    let hidden = req["hidden"].as_bool().unwrap_or(false);
    let limit = req["limit"].as_u64().unwrap_or(3000) as usize;
    if query.is_empty() {
        ctx.out.event("search", json!({"token": token, "entries": [], "done": true, "scanned": 0}));
        return;
    }
    if req["content"].as_bool().unwrap_or(false) {
        content(ctx, &token, &root, &query, hidden, limit, stop);
        return;
    }
    let folded = util::fold(&query);
    let glob: Option<Vec<char>> = (folded.contains('*') || folded.contains('?')).then(|| folded.chars().collect());
    let terms: Vec<String> = folded.split_whitespace().map(str::to_string).collect();
    let roles = crate::places::roles();
    let empty = HashSet::new();
    let mut batch: Vec<(u32, Value)> = Vec::new();
    let mut found = 0usize;
    let mut scanned = 0usize;
    let mut last = Instant::now();
    // Breadth first: near results come before deep ones.
    let mut queue = std::collections::VecDeque::from([root.clone()]);
    let mut seen = HashSet::new();
    while let Some(dir) = queue.pop_front() {
        if stop.load(Ordering::Relaxed) {
            return;
        }
        let Ok(rd) = fs::read_dir(&dir) else { continue };
        for de in rd.flatten() {
            let name = de.file_name().to_string_lossy().into_owned();
            if !hidden && name.starts_with('.') {
                continue;
            }
            scanned += 1;
            let path = de.path();
            let ft = de.file_type().ok();
            if ft.map(|t| t.is_dir()).unwrap_or(false) {
                let p = path.to_string_lossy();
                if !SKIP.iter().any(|s| p == *s) && seen.insert(path.clone()) {
                    queue.push_back(path.clone());
                }
            }
            if let Some(s) = score(&name, &terms, glob.as_deref()) {
                if let Some(mut e) = crate::list::entry(ctx, &path, &roles, &empty) {
                    e["score"] = json!(s);
                    batch.push((s, e));
                    found += 1;
                }
            }
            if found >= limit {
                break;
            }
            if last.elapsed().as_millis() > 120 && !batch.is_empty() {
                flush(ctx, &token, &mut batch, false, scanned);
                last = Instant::now();
            }
        }
        if found >= limit {
            break;
        }
    }
    flush(ctx, &token, &mut batch, true, scanned);
}

fn flush(ctx: &Ctx, token: &str, batch: &mut Vec<(u32, Value)>, done: bool, scanned: usize) {
    batch.sort_by_key(|(s, _)| *s);
    let entries: Vec<Value> = batch.drain(..).map(|(_, e)| e).collect();
    ctx.out.event("search", json!({"token": token, "entries": entries, "done": done, "scanned": scanned}));
}

fn content(ctx: &Ctx, token: &str, root: &PathBuf, query: &str, hidden: bool, limit: usize, stop: Arc<AtomicBool>) {
    use std::io::BufRead;
    use std::process::{Command, Stdio};
    let mut cmd = Command::new("rg");
    cmd.args(["--json", "--max-count", "1", "--ignore-case", "--fixed-strings", "--max-filesize", "50M", "--max-columns", "300"]);
    if hidden {
        cmd.arg("--hidden");
    }
    cmd.arg("--").arg(query).arg(root).stdin(Stdio::null()).stdout(Stdio::piped()).stderr(Stdio::null());
    let Ok(mut child) = cmd.spawn() else {
        ctx.out.event("search", json!({"token": token, "entries": [], "done": true, "error": "norg"}));
        return;
    };
    let roles = crate::places::roles();
    let empty = HashSet::new();
    let mut batch = Vec::new();
    let mut found = 0;
    let mut last = Instant::now();
    let stdout = child.stdout.take().unwrap();
    for line in std::io::BufReader::new(stdout).lines().map_while(Result::ok) {
        if stop.load(Ordering::Relaxed) || found >= limit {
            let _ = child.kill();
            break;
        }
        let Ok(v) = serde_json::from_str::<Value>(&line) else { continue };
        if v["type"] != "match" {
            continue;
        }
        let d = &v["data"];
        let Some(p) = d["path"]["text"].as_str() else { continue };
        if let Some(mut e) = crate::list::entry(ctx, &PathBuf::from(p), &roles, &empty) {
            e["snippet"] = json!(d["lines"]["text"].as_str().unwrap_or("").trim());
            e["line"] = d["line_number"].clone();
            batch.push((0, e));
            found += 1;
        }
        if last.elapsed().as_millis() > 120 {
            flush(ctx, token, &mut batch, false, found);
            last = Instant::now();
        }
    }
    let _ = child.wait();
    if !stop.load(Ordering::Relaxed) {
        flush(ctx, token, &mut batch, true, found);
    }
}
