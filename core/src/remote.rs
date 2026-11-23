// Servers: an address (sftp, smb, ftp, dav, nfs and the rest gvfs knows) mounted through `gio mount`, which asks what
// the server wants on the terminal. Each question goes to the interface as an "ask" event and its answer comes back
// through "connect_answer", while gio waits. A connected server opens at its FUSE folder in the session's gvfs folder. A
// password the person keeps goes to the Secret Service under the attributes gvfs reads itself.

use crate::{util, Ctx};
use serde_json::{json, Value};
use std::collections::HashMap;
use std::io::{Read, Write};
use std::process::{Child, Command, Stdio};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::mpsc::{channel, Sender};
use std::sync::{Arc, Mutex};

struct Talk {
    tx: Sender<Value>,
    child: Arc<Mutex<Child>>,
    stop: Arc<AtomicBool>,
}

/// The connections waiting on the person, by token.
#[derive(Default)]
pub struct Talks(Mutex<HashMap<String, Talk>>);

#[derive(Debug, Default, PartialEq)]
pub struct Address {
    pub scheme: String,
    pub user: String,
    pub domain: String,
    pub host: String,
    pub port: String,
    pub path: String,
}

/// scheme://[domain;]user[:secret]@host[:port]/path, with [v6] hosts. None when it is no address.
pub fn parse(uri: &str) -> Option<Address> {
    let (scheme, rest) = uri.split_once("://")?;
    if scheme.is_empty() || !scheme.chars().all(|c| c.is_ascii_alphanumeric() || "+.-".contains(c)) {
        return None;
    }
    let decode = |s: &str| percent_encoding::percent_decode_str(s).decode_utf8_lossy().into_owned();
    let (auth, path) = rest.find('/').map(|i| (&rest[..i], &rest[i..])).unwrap_or((rest, ""));
    let (info, hostport) = auth.rsplit_once('@').unwrap_or(("", auth));
    let info = info.split(':').next().unwrap_or("");
    let (domain, user) = info.split_once(';').unwrap_or(("", info));
    let (host, port) = match hostport.strip_prefix('[') {
        Some(v6) => {
            let (h, p) = v6.split_once(']').unwrap_or((v6, ""));
            (h, p.trim_start_matches(':'))
        }
        None => hostport.rsplit_once(':').unwrap_or((hostport, "")),
    };
    Some(Address { scheme: scheme.to_ascii_lowercase(), user: decode(user), domain: decode(domain), host: decode(host), port: port.to_string(), path: decode(path) })
}

/// The schemes the installed gvfs backends open; None when their list is nowhere to be found.
fn schemes() -> Option<Vec<String>> {
    let mut out = Vec::new();
    for dir in util::data_dirs() {
        let Ok(rd) = std::fs::read_dir(dir.join("gvfs/mounts")) else { continue };
        for de in rd.flatten() {
            let text = std::fs::read_to_string(de.path()).unwrap_or_default();
            let (mut scheme, mut types) = (None, Vec::new());
            for l in text.lines() {
                let list = |v: &str| v.split(';').map(|s| s.trim().to_string()).filter(|s| !s.is_empty()).collect::<Vec<_>>();
                if let Some(v) = l.strip_prefix("Scheme=") {
                    scheme = Some(v.trim().to_string());
                } else if let Some(v) = l.strip_prefix("SchemeAliases=") {
                    out.extend(list(v));
                } else if let Some(v) = l.strip_prefix("Type=") {
                    types = list(v);
                }
            }
            match scheme {
                Some(s) => out.push(s),
                None => out.extend(types),
            }
        }
    }
    (!out.is_empty()).then_some(out)
}

fn info_line(target: &str, key: &str) -> Option<String> {
    // gio translates its labels ("ruta local:"): read them in C.
    let text = util::run_out("env", &["LC_ALL=C", "gio", "info", "-a", "standard::type", target], 8000)?;
    text.lines().find_map(|l| l.strip_prefix(key)).map(|v| v.trim().to_string()).filter(|v| !v.is_empty())
}

/// Where a mounted address shows as a folder.
fn local_path(uri: &str) -> Option<String> {
    info_line(uri, "local path:").filter(|p| std::path::Path::new(p).exists())
}

/// The address behind a folder of a gvfs mount, for a bookmark that still opens after the next login.
pub fn uri_of(path: &str) -> Option<String> {
    info_line(path, "uri:").filter(|u| !u.starts_with("file://"))
}

/// The shares a Windows or Samba server offers, for an address that names none.
fn shares(uri: &str) -> Vec<Value> {
    let text = util::run_out("gio", &["list", "-u", uri], 15000).unwrap_or_default();
    text.lines()
        .filter_map(|l| l.split('\t').next())
        .filter(|u| u.contains("://"))
        .map(|u| {
            let name = u.trim_end_matches('/').rsplit('/').next().unwrap_or(u);
            json!({"name": percent_encoding::percent_decode_str(name).decode_utf8_lossy(), "uri": u})
        })
        .collect()
}

/// gio's own questions end its output: "User [me]: ", "Domain: ", "Password: ", "Choice: ".
fn prompt(tail: &str) -> Option<(&'static str, String)> {
    let t = tail.strip_suffix(": ")?;
    ["User", "Domain", "Password", "Choice"].into_iter().find_map(|what| {
        if t == what {
            return Some((what, String::new()));
        }
        t.strip_prefix(what)?.strip_prefix(" [")?.strip_suffix(']').map(|d| (what, d.to_string()))
    })
}

/// A numbered choice of a question: "[1] Log In Anyway".
fn choice(line: &str) -> Option<&str> {
    let rest = line.strip_prefix('[')?;
    let (n, text) = rest.split_once("] ")?;
    n.chars().all(|c| c.is_ascii_digit()).then_some(text)
}

/// The words of gio's last error line, without "gio: ADDRESS: ".
fn error_text(stderr: &str, uri: &str) -> String {
    let line = stderr.lines().rev().find(|l| !l.trim().is_empty()).unwrap_or("").trim();
    let line = line.strip_prefix("gio: ").unwrap_or(line);
    let line = line.strip_prefix(uri).and_then(|l| l.strip_prefix(": ")).unwrap_or(line);
    if line.is_empty() { "cancelled".into() } else { line.to_string() }
}

fn keyring_attrs(a: &Address, user: &str, domain: &str) -> Vec<String> {
    let mut v = vec!["protocol".to_string(), a.scheme.clone(), "server".into(), a.host.clone()];
    for (k, val) in [("port", a.port.as_str()), ("user", user), ("domain", domain)] {
        if !val.is_empty() {
            v.push(k.into());
            v.push(val.into());
        }
    }
    v
}

/// The first password kept for this server, and the name it goes with.
fn keyring_find(a: &Address) -> Option<(String, String)> {
    let mut args = vec!["search".to_string(), "--unlock".into()];
    args.extend(keyring_attrs(a, &a.user, &a.domain));
    let out = Command::new("secret-tool").args(&args).stdin(Stdio::null()).output().ok()?;
    found(&format!("{}{}", String::from_utf8_lossy(&out.stdout), String::from_utf8_lossy(&out.stderr)))
}

fn found(text: &str) -> Option<(String, String)> {
    let (mut user, mut secret) = (String::new(), None);
    for l in text.lines() {
        if l.starts_with('[') && secret.is_some() {
            break;
        }
        if let Some(v) = l.strip_prefix("secret = ") {
            secret = Some(v.to_string());
        } else if let Some(v) = l.strip_prefix("attribute.user = ") {
            user = v.to_string();
        }
    }
    Some((user, secret?))
}

fn keyring_store(a: &Address, user: &str, domain: &str, password: &str) -> bool {
    let at = if user.is_empty() { String::new() } else { format!("{user}@") };
    let mut args = vec!["store".to_string(), format!("--label={}://{at}{}", a.scheme, a.host), "xdg:schema".into(), "org.gnome.keyring.NetworkPassword".into()];
    args.extend(keyring_attrs(a, user, domain));
    let Ok(mut child) = Command::new("secret-tool").args(&args).stdin(Stdio::piped()).stdout(Stdio::null()).stderr(Stdio::null()).spawn() else { return false };
    if let Some(mut input) = child.stdin.take() {
        let _ = input.write_all(password.as_bytes());
    }
    child.wait().map(|s| s.success()).unwrap_or(false)
}

pub fn connect(ctx: &Ctx, req: &Value) -> Result<Value, String> {
    let uri = req["uri"].as_str().unwrap_or("").trim().to_string();
    let token = req["token"].as_str().unwrap_or("connect").to_string();
    let Some(addr) = parse(&uri) else { return Err("badaddress".into()) };
    if util::which("gio").is_none() {
        return Err("nogio".into());
    }
    if schemes().is_some_and(|known| !known.contains(&addr.scheme)) {
        return Err("noscheme".into());
    }
    // smb://server alone lists its shares; anything else opens where it is, mounted already or not.
    let list = addr.scheme == "smb" && !addr.host.is_empty() && addr.path.trim_matches('/').is_empty();
    if !list {
        if let Some(p) = local_path(&uri) {
            return Ok(json!({"path": p}));
        }
    }
    let mut child = Command::new("gio").args(["mount", &uri]).stdin(Stdio::piped()).stdout(Stdio::piped()).stderr(Stdio::piped()).spawn().map_err(|_| "nogio".to_string())?;
    let (Some(mut out), Some(mut input), Some(mut err)) = (child.stdout.take(), child.stdin.take(), child.stderr.take()) else { return Err("nogio".into()) };
    let errs = std::thread::spawn(move || {
        let mut s = String::new();
        let _ = err.read_to_string(&mut s);
        s
    });
    let child = Arc::new(Mutex::new(child));
    let stop = Arc::new(AtomicBool::new(false));
    let (tx, rx) = channel::<Value>();
    ctx.talks.0.lock().unwrap().insert(token.clone(), Talk { tx, child: child.clone(), stop: stop.clone() });

    let keyring = util::which("secret-tool").is_some();
    let (mut raw, mut said, mut buf) = (Vec::<u8>::new(), Vec::<String>::new(), [0u8; 4096]);
    // gio says the server's words once at the start of each round of questions; a second round means the first answers failed.
    let (mut message, mut rounds, mut by_person, mut tried_keyring) = (String::new(), 0, false, false);
    let mut form: Option<Value> = None;
    let mut defaults = (String::new(), String::new());
    let mut keep: Option<(String, String, String)> = None;
    // The person turned the server down: a choice past the first ("Cancel Login") that gio ends on.
    let mut declined = false;
    loop {
        let n = match out.read(&mut buf) {
            Ok(0) | Err(_) => break,
            Ok(n) => n,
        };
        raw.extend_from_slice(&buf[..n]);
        while let Some(i) = raw.iter().position(|&b| b == b'\n') {
            let line: Vec<u8> = raw.drain(..=i).collect();
            said.push(String::from_utf8_lossy(&line[..line.len() - 1]).trim_end().to_string());
        }
        let Some((what, default)) = prompt(&String::from_utf8_lossy(&raw)) else { continue };
        raw.clear();
        let answer = if what == "Choice" {
            let choices: Vec<&str> = said.iter().filter_map(|l| choice(l)).collect();
            let text = said.iter().filter(|l| choice(l).is_none() && !l.is_empty()).cloned().collect::<Vec<_>>().join("\n");
            ctx.out.event("ask", json!({"token": token, "kind": "question", "message": text, "choices": choices}));
            said.clear();
            let Ok(a) = rx.recv() else { break };
            if a["cancel"].as_bool() == Some(true) {
                break;
            }
            let n = a["choice"].as_u64().unwrap_or(0);
            declined = n > 0;
            format!("{}\n", n + 1)
        } else {
            if !said.is_empty() {
                message = said.iter().filter(|l| !l.is_empty()).cloned().collect::<Vec<_>>().join("\n");
                said.clear();
                if form.take().is_some() {
                    rounds += 1;
                }
            }
            match what {
                "User" => defaults.0 = default.clone(),
                "Domain" => defaults.1 = default.clone(),
                _ => {}
            }
            if form.is_none() && keyring && !tried_keyring {
                tried_keyring = true;
                form = keyring_find(&addr).map(|(u, p)| json!({"user": u, "password": p}));
                by_person = false;
            }
            if form.is_none() {
                let fields: &[&str] = match what {
                    "User" if addr.scheme == "smb" => &["user", "domain", "password"],
                    "User" => &["user", "password"],
                    "Domain" => &["domain", "password"],
                    _ => &["password"],
                };
                ctx.out.event("ask", json!({
                    "token": token, "kind": "password", "message": message, "fields": fields,
                    "user": if what == "User" { default.clone() } else { addr.user.clone() },
                    "domain": if what == "Domain" { default.clone() } else { addr.domain.clone() },
                    "again": rounds > 0 && by_person, "keyring": keyring,
                }));
                let Ok(a) = rx.recv() else { break };
                if a["cancel"].as_bool() == Some(true) {
                    break;
                }
                by_person = true;
                declined = false;
                let s = |k: &str| a[k].as_str().unwrap_or("").to_string();
                keep = a["remember"].as_bool().unwrap_or(false).then(|| (s("user"), s("domain"), s("password")));
                form = Some(a);
            }
            let key = match what {
                "User" => "user",
                "Domain" => "domain",
                _ => "password",
            };
            // An empty name or domain takes the one gio offers.
            format!("{}\n", form.as_ref().and_then(|f| f[key].as_str()).unwrap_or("").replace('\n', ""))
        };
        if input.write_all(answer.as_bytes()).and_then(|_| input.flush()).is_err() {
            break;
        }
    }
    ctx.talks.0.lock().unwrap().remove(&token);
    // Closed input ends a gio that still waits for an answer.
    drop(input);
    let ok = child.lock().unwrap().wait().map(|s| s.success()).unwrap_or(false);
    let stderr = errs.join().unwrap_or_default();
    if stop.load(Ordering::Relaxed) || (declined && !ok) {
        return Err("cancelled".into());
    }
    if list && ok {
        let found = shares(&uri);
        if !found.is_empty() {
            return Ok(json!({"shares": found}));
        }
    }
    // The FUSE folder can show a moment after gio returns.
    let found = (0..if ok { 20 } else { 1 }).find_map(|i| {
        if i > 0 {
            std::thread::sleep(std::time::Duration::from_millis(100));
        }
        local_path(&uri)
    });
    match found {
        Some(p) => {
            let mut v = json!({"path": p});
            if let Some((u, d, pw)) = keep.filter(|_| by_person) {
                let user = if u.is_empty() { if addr.user.is_empty() { defaults.0 } else { addr.user.clone() } } else { u };
                let domain = if d.is_empty() { if addr.domain.is_empty() { defaults.1 } else { addr.domain.clone() } } else { d };
                v["remembered"] = json!(keyring_store(&addr, &user, &domain, &pw));
            }
            Ok(v)
        }
        None if ok => Err("nofuse".into()),
        None => Err(error_text(&stderr, &uri)),
    }
}

/// The person's answer to an "ask" event, or {cancel: true}, which also stops a connection still on its way.
pub fn answer(ctx: &Ctx, req: &Value) -> Result<Value, String> {
    let talks = ctx.talks.0.lock().unwrap();
    if let Some(t) = talks.get(req["token"].as_str().unwrap_or("")) {
        if req["cancel"].as_bool() == Some(true) {
            t.stop.store(true, Ordering::Relaxed);
            let _ = t.child.lock().unwrap().kill();
        }
        let _ = t.tx.send(req.clone());
    }
    Ok(json!({}))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn an_address_comes_apart() {
        let a = parse("smb://WORK;ana%20m:pw@nas.local:4450/Media%20Files/x").unwrap();
        assert_eq!((a.scheme.as_str(), a.domain.as_str(), a.user.as_str(), a.host.as_str(), a.port.as_str(), a.path.as_str()), ("smb", "WORK", "ana m", "nas.local", "4450", "/Media Files/x"));
        let b = parse("SFTP://[fe80::1]:2222").unwrap();
        assert_eq!((b.scheme.as_str(), b.host.as_str(), b.port.as_str(), b.path.as_str()), ("sftp", "fe80::1", "2222", ""));
        assert_eq!(parse("localtest:///").unwrap().host, "");
        assert!(parse("/home/a").is_none());
        assert!(parse("a b://x").is_none());
    }

    #[test]
    fn gio_prompts_are_read() {
        assert_eq!(prompt("User [ana]: "), Some(("User", "ana".to_string())));
        assert_eq!(prompt("Password: "), Some(("Password", String::new())));
        assert_eq!(prompt("Choice: "), Some(("Choice", String::new())));
        assert_eq!(prompt("Pass"), None);
        assert_eq!(prompt("Username: "), None);
        assert_eq!(choice("[2] Cancel Login"), Some("Cancel Login"));
        assert_eq!(choice("[x] no"), None);
    }

    #[test]
    fn gio_errors_lose_their_prefix() {
        assert_eq!(error_text("gio: sftp://h/: Connection refused\n", "sftp://h/"), "Connection refused");
        assert_eq!(error_text("", "sftp://h/"), "cancelled");
    }

    #[test]
    fn a_kept_password_is_found() {
        let text = "[/32]\nlabel = x\nsecret = pw1\nattribute.protocol = dav\nattribute.user = demo\n[/33]\nsecret = other\n";
        assert_eq!(found(text), Some(("demo".to_string(), "pw1".to_string())));
        assert_eq!(found("nothing"), None);
    }
}
