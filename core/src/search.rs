// Search below a folder, streamed across CPU cores: by name (exact, word-boundary, substring, fuzzy subsequence or
// glob such as *.png), or by content through ripgrep with the first matching line shown. Best matches first per batch.

use crate::util;
use crate::Ctx;
use serde_json::{json, Value};
use std::collections::{HashSet, VecDeque};
use std::fs;
use std::path::PathBuf;
use std::sync::atomic::{AtomicBool, AtomicUsize, Ordering};
use std::sync::{Arc, Condvar, Mutex};
use std::time::Instant;

const SKIP: &[&str] = &["/proc", "/sys", "/dev", "/run", "/tmp/.X11-unix"];

pub fn score(name: &str, terms: &[String], glob: Option<&[char]>) -> Option<u32> {
    let folded = util::fold(name);
    if let Some(g) = glob {
        let chars: Vec<char> = folded.chars().collect();
        return glob_match(g, &chars).then_some(10);
    }
    if terms.is_empty() {
        return None;
    }
    // 1. Substring match on every term (highest priority).
    let mut sub = 0u32;
    let mut all_sub = true;
    for t in terms {
        if let Some(at) = folded.find(t.as_str()) {
            sub += if at == 0 {
                0
            } else if folded[..at].ends_with([' ', '-', '_', '.']) {
                1
            } else {
                3
            };
        } else {
            all_sub = false;
            break;
        }
    }
    if all_sub {
        if terms.len() == 1 && folded == terms[0] {
            return Some(0);
        }
        return Some(sub + 1);
    }
    // 2. Fuzzy subsequence match for a single word >= 3 chars (e.g. "hpq" -> "HomePane.qml").
    if terms.len() == 1 && terms[0].chars().count() >= 3 {
        return fuzzy_score(name, &folded, &terms[0]);
    }
    None
}

fn fuzzy_score(orig: &str, folded: &str, needle: &str) -> Option<u32> {
    let n: Vec<char> = needle.chars().collect();
    let h: Vec<char> = folded.chars().collect();
    let o: Vec<char> = orig.chars().collect();
    if n.len() > h.len() {
        return None;
    }
    let mut ni = 0usize;
    let mut prev: Option<usize> = None;
    let mut gaps = 0u32;
    let mut bonus = 0u32;
    for (hi, &ch) in h.iter().enumerate() {
        if ch == n[ni] {
            if let Some(p) = prev {
                if hi == p + 1 {
                    bonus += 2; // consecutive run
                } else {
                    gaps += (hi - p - 1) as u32;
                }
            } else if hi == 0 {
                bonus += 3; // prefix hit
            }
            // Word boundary or CamelCase transition in original name.
            if hi > 0 {
                let prev_c = o.get(hi - 1).copied().unwrap_or(' ');
                let curr_c = o.get(hi).copied().unwrap_or(' ');
                if matches!(prev_c, ' ' | '-' | '_' | '.') || (curr_c.is_uppercase() && prev_c.is_lowercase()) {
                    bonus += 2;
                }
            }
            prev = Some(hi);
            ni += 1;
            if ni == n.len() {
                let base = 24u32.saturating_add(gaps.min(60));
                return Some(base.saturating_sub(bonus.min(12)));
            }
        }
    }
    None
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

struct Queue {
    dirs: VecDeque<PathBuf>,
    seen: HashSet<PathBuf>,
    active: usize,
    done: bool,
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

    let mut seen = HashSet::new();
    seen.insert(root.clone());
    let work = (
        Mutex::new(Queue { dirs: VecDeque::from([root]), seen, active: 0, done: false }),
        Condvar::new(),
    );
    let batch: Mutex<(Vec<(u32, Value)>, Instant)> = Mutex::new((Vec::new(), Instant::now()));
    let found = AtomicUsize::new(0);
    let scanned = AtomicUsize::new(0);
    let workers = std::thread::available_parallelism().map(|n| n.get()).unwrap_or(4).clamp(2, 8);

    std::thread::scope(|s| {
        for _ in 0..workers {
            let stop = &stop;
            let work = &work;
            let batch = &batch;
            let found = &found;
            let scanned = &scanned;
            let terms = &terms;
            let glob = &glob;
            let roles = &roles;
            let empty = &empty;
            let token = &token;
            s.spawn(move || loop {
                let dir = {
                    let (mu, cv) = work;
                    let mut q = mu.lock().unwrap();
                    loop {
                        if stop.load(Ordering::Relaxed) || found.load(Ordering::Relaxed) >= limit {
                            q.done = true;
                            cv.notify_all();
                            return;
                        }
                        if let Some(d) = q.dirs.pop_front() {
                            q.active += 1;
                            break d;
                        }
                        if q.active == 0 {
                            q.done = true;
                            cv.notify_all();
                            return;
                        }
                        q = cv.wait(q).unwrap();
                    }
                };

                let mut subdirs = Vec::new();
                let mut hits = Vec::new();
                let mut local_scanned = 0usize;

                if let Ok(rd) = fs::read_dir(&dir) {
                    for de in rd.flatten() {
                        if stop.load(Ordering::Relaxed) || found.load(Ordering::Relaxed) >= limit {
                            break;
                        }
                        let name = de.file_name().to_string_lossy().into_owned();
                        if !hidden && name.starts_with('.') {
                            continue;
                        }
                        local_scanned += 1;
                        let path = de.path();
                        if de.file_type().map(|t| t.is_dir()).unwrap_or(false) {
                            let p = path.to_string_lossy();
                            if !SKIP.iter().any(|sk| p == *sk) {
                                subdirs.push(path.clone());
                            }
                        }
                        if let Some(sc) = score(&name, terms, glob.as_deref()) {
                            let prev = found.fetch_add(1, Ordering::Relaxed);
                            if prev >= limit {
                                break;
                            }
                            if let Some(mut e) = crate::list::entry(ctx, &path, roles, empty) {
                                e["score"] = json!(sc);
                                hits.push((sc, e));
                            }
                        }
                    }
                }

                let tot_scanned = scanned.fetch_add(local_scanned, Ordering::Relaxed) + local_scanned;
                if !hits.is_empty() {
                    let mut b = batch.lock().unwrap();
                    b.0.extend(hits);
                    if b.1.elapsed().as_millis() >= 90 && !b.0.is_empty() {
                        flush(ctx, token, &mut b.0, false, tot_scanned);
                        b.1 = Instant::now();
                    }
                }

                let (mu, cv) = work;
                let mut q = mu.lock().unwrap();
                for sd in subdirs {
                    if q.seen.insert(sd.clone()) {
                        q.dirs.push_back(sd);
                    }
                }
                q.active -= 1;
                if q.dirs.is_empty() && q.active == 0 {
                    q.done = true;
                }
                cv.notify_all();
            });
        }
    });

    if !stop.load(Ordering::Relaxed) {
        let mut b = batch.lock().unwrap();
        flush(ctx, &token, &mut b.0, true, scanned.load(Ordering::Relaxed));
    }
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

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn scoring_prefers_exact_then_substring_then_fuzzy() {
        let exact = score("HomePane.qml", &["homepane.qml".into()], None).unwrap();
        let prefix = score("HomePane.qml", &["home".into()], None).unwrap();
        let inner = score("HomePane.qml", &["pane".into()], None).unwrap();
        let fuzzy = score("HomePane.qml", &["hpq".into()], None).unwrap();
        assert_eq!(exact, 0);
        assert!(prefix < inner);
        assert!(inner < fuzzy);
        assert!(score("notes.md", &["hpq".into()], None).is_none());
    }

    #[test]
    fn glob_matches_wildcards() {
        let g: Vec<char> = "*.qml".chars().collect();
        assert!(score("HomePane.qml", &[], Some(&g)).is_some());
        assert!(score("notes.md", &[], Some(&g)).is_none());
    }
}
