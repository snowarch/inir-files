// Opening files: the applications installed (desktop entries, localised), which of them take a type (mimeapps.list
// defaults, added and removed associations, the type's ancestors), the person's choice of default, launching with the
// Exec field codes expanded, a terminal in a folder, and the clipboard in the format other file managers read.

use crate::util;
use crate::Ctx;
use serde_json::{json, Value};
use std::collections::HashMap;
use std::fs;
use std::path::{Path, PathBuf};

#[derive(Clone)]
pub struct App {
    pub id: String,
    pub name: String,
    pub generic: String,
    pub icon: String,
    pub exec: String,
    pub mimes: Vec<String>,
    pub terminal: bool,
    pub path: PathBuf,
    pub hidden: bool,
}

fn locale_keys() -> Vec<String> {
    let raw = ["LC_ALL", "LC_MESSAGES", "LANG"].iter().find_map(|k| std::env::var(k).ok().filter(|v| !v.is_empty())).unwrap_or_default();
    let base = raw.split(['.', '@']).next().unwrap_or("").to_string();
    let short = base.split('_').next().unwrap_or("").to_string();
    let mut keys = Vec::new();
    if !base.is_empty() {
        keys.push(base);
    }
    if !short.is_empty() && !keys.contains(&short) {
        keys.push(short);
    }
    keys
}

fn parse(path: &Path, id: String, locales: &[String]) -> Option<App> {
    let text = fs::read_to_string(path).ok()?;
    let mut in_entry = false;
    let mut kv: HashMap<String, String> = HashMap::new();
    for line in text.lines() {
        let line = line.trim();
        if line.starts_with('[') {
            in_entry = line == "[Desktop Entry]";
            continue;
        }
        if !in_entry {
            continue;
        }
        if let Some((k, v)) = line.split_once('=') {
            kv.entry(k.trim().to_string()).or_insert_with(|| v.trim().to_string());
        }
    }
    if kv.get("Type").map(String::as_str) != Some("Application") {
        return None;
    }
    let local = |key: &str| locales.iter().find_map(|l| kv.get(&format!("{key}[{l}]")).cloned()).or_else(|| kv.get(key).cloned()).unwrap_or_default();
    if let Some(t) = kv.get("TryExec").filter(|t| !t.is_empty()) {
        util::which(t)?;
    }
    Some(App {
        id,
        name: local("Name"),
        generic: local("GenericName"),
        icon: kv.get("Icon").cloned().unwrap_or_default(),
        exec: kv.get("Exec").cloned().unwrap_or_default(),
        mimes: kv.get("MimeType").map(|m| m.split(';').filter(|s| !s.is_empty()).map(str::to_string).collect()).unwrap_or_default(),
        terminal: kv.get("Terminal").map(|t| t == "true").unwrap_or(false),
        path: path.to_path_buf(),
        hidden: kv.get("NoDisplay").map(|t| t == "true").unwrap_or(false) || kv.get("Hidden").map(|t| t == "true").unwrap_or(false),
    })
}

fn scan_dir(dir: &Path, prefix: &str, out: &mut HashMap<String, App>, locales: &[String]) {
    let Ok(rd) = fs::read_dir(dir) else { return };
    for de in rd.flatten() {
        let p = de.path();
        let name = de.file_name().to_string_lossy().into_owned();
        if p.is_dir() {
            scan_dir(&p, &format!("{prefix}{name}-"), out, locales);
        } else if name.ends_with(".desktop") {
            let id = format!("{prefix}{name}");
            if out.contains_key(&id) {
                continue;
            }
            if let Some(app) = parse(&p, id.clone(), locales) {
                out.insert(id, app);
            } else {
                // A higher directory's entry that is not an application still hides the lower one.
                out.insert(id.clone(), App { id, name: String::new(), generic: String::new(), icon: String::new(), exec: String::new(), mimes: vec![], terminal: false, path: p, hidden: true });
            }
        }
    }
}

pub fn all() -> HashMap<String, App> {
    let locales = locale_keys();
    let mut out = HashMap::new();
    for d in util::data_dirs() {
        scan_dir(&d.join("applications"), "", &mut out, &locales);
    }
    out.retain(|_, a| !a.exec.is_empty());
    out
}

struct MimeApps {
    defaults: HashMap<String, Vec<String>>,
    added: HashMap<String, Vec<String>>,
    removed: HashMap<String, Vec<String>>,
}

fn mimeapps() -> MimeApps {
    let mut m = MimeApps { defaults: HashMap::new(), added: HashMap::new(), removed: HashMap::new() };
    let desktops: Vec<String> = std::env::var("XDG_CURRENT_DESKTOP").unwrap_or_default().split(':').filter(|s| !s.is_empty()).map(|s| s.to_lowercase()).collect();
    let mut files = Vec::new();
    for d in util::config_dirs() {
        for de in &desktops {
            files.push(d.join(format!("{de}-mimeapps.list")));
        }
        files.push(d.join("mimeapps.list"));
    }
    for d in util::data_dirs() {
        for de in &desktops {
            files.push(d.join(format!("applications/{de}-mimeapps.list")));
        }
        files.push(d.join("applications/mimeapps.list"));
    }
    for f in files {
        let Ok(text) = fs::read_to_string(&f) else { continue };
        let mut section = "";
        for line in text.lines() {
            let line = line.trim();
            if line.starts_with('[') {
                section = match line {
                    "[Default Applications]" => "d",
                    "[Added Associations]" => "a",
                    "[Removed Associations]" => "r",
                    _ => "",
                };
                continue;
            }
            let Some((k, v)) = line.split_once('=') else { continue };
            let ids: Vec<String> = v.split(';').filter(|s| !s.is_empty()).map(str::to_string).collect();
            let map = match section { "d" => &mut m.defaults, "a" => &mut m.added, "r" => &mut m.removed, _ => continue };
            // Earlier files win; later ones only add.
            map.entry(k.to_string()).or_default().extend(ids);
        }
    }
    m
}

/// (default app id, every app that takes the type, best first).
pub fn for_mime(ctx: &Ctx, mime: &str, apps: &HashMap<String, App>) -> (Option<String>, Vec<String>) {
    let ma = mimeapps();
    let lineage = ctx.mime.lineage(mime);
    let mut order: Vec<String> = Vec::new();
    let mut default = None;
    for m in &lineage {
        let removed = ma.removed.get(m).cloned().unwrap_or_default();
        for id in ma.defaults.get(m).into_iter().flatten() {
            if apps.contains_key(id) && !removed.contains(id) {
                if default.is_none() {
                    default = Some(id.clone());
                }
                if !order.contains(id) {
                    order.push(id.clone());
                }
            }
        }
        for id in ma.added.get(m).into_iter().flatten() {
            if apps.contains_key(id) && !removed.contains(id) && !order.contains(id) {
                order.push(id.clone());
            }
        }
        let mut found: Vec<&App> = apps.values().filter(|a| a.mimes.iter().any(|x| x == m) && !removed.contains(&a.id) && !order.contains(&a.id)).collect();
        found.sort_by(|a, b| a.hidden.cmp(&b.hidden).then_with(|| util::natural_cmp(&a.name, &b.name)));
        order.extend(found.into_iter().map(|a| a.id.clone()));
        // text/plain is everything's ancestor in text: its editors are offered, but after the type's own apps.
    }
    if default.is_none() {
        default = order.first().cloned();
    }
    (default, order)
}

fn app_json(a: &App) -> Value {
    json!({"id": a.id, "name": a.name, "generic": a.generic, "icon": a.icon, "terminal": a.terminal, "hidden": a.hidden})
}

pub fn apps_op(ctx: &Ctx, req: &Value) -> Value {
    let apps = all();
    let mime = req["mime"].as_str().unwrap_or("");
    let (default, ids) = for_mime(ctx, mime, &apps);
    let list: Vec<Value> = ids.iter().filter_map(|id| apps.get(id)).filter(|a| !a.hidden || Some(&a.id) == default.as_ref()).map(app_json).collect();
    json!({"default": default, "apps": list})
}

pub fn all_apps_op() -> Value {
    let mut list: Vec<App> = all().into_values().filter(|a| !a.hidden).collect();
    list.sort_by(|a, b| util::natural_cmp(&a.name, &b.name));
    json!({"apps": list.iter().map(app_json).collect::<Vec<_>>()})
}

/// The command line an entry asks for, its field codes filled with these files; one command per file when the
/// entry takes one at a time.
fn commands(app: &App, files: &[PathBuf]) -> Vec<Vec<String>> {
    let words = crate::thumbs::split_exec(&app.exec);
    let multi = words.iter().any(|w| w.contains("%F") || w.contains("%U"));
    let single = words.iter().any(|w| w.contains("%f") || w.contains("%u"));
    let groups: Vec<Vec<PathBuf>> = if multi || files.is_empty() { vec![files.to_vec()] } else { files.iter().map(|f| vec![f.clone()]).collect() };
    groups.into_iter().map(|group| {
        let mut argv = Vec::new();
        for w in &words {
            match w.as_str() {
                "%F" => argv.extend(group.iter().map(|f| f.to_string_lossy().into_owned())),
                "%U" => argv.extend(group.iter().map(|f| util::uri(f))),
                "%f" => argv.extend(group.first().map(|f| f.to_string_lossy().into_owned())),
                "%u" => argv.extend(group.first().map(|f| util::uri(f))),
                "%i" => {
                    if !app.icon.is_empty() {
                        argv.push("--icon".into());
                        argv.push(app.icon.clone());
                    }
                }
                "%c" => argv.push(app.name.clone()),
                "%k" => argv.push(app.path.to_string_lossy().into_owned()),
                "%d" | "%D" | "%n" | "%N" | "%v" | "%m" => {}
                _ => {
                    let first = group.first().map(|f| f.to_string_lossy().into_owned()).unwrap_or_default();
                    argv.push(w.replace("%f", &first).replace("%u", &group.first().map(|f| util::uri(f)).unwrap_or_default()).replace("%c", &app.name).replace("%k", &app.path.to_string_lossy()).replace("%%", "%"))
                }
            }
        }
        // An entry with no field code still gets the files: what the person asked to open.
        if !multi && !single && !group.is_empty() {
            argv.extend(group.iter().map(|f| f.to_string_lossy().into_owned()));
        }
        argv
    }).collect()
}

fn terminal_argv(custom: &str) -> Vec<String> {
    if !custom.trim().is_empty() {
        return crate::thumbs::split_exec(custom);
    }
    if let Ok(t) = std::env::var("TERMINAL") {
        if util::which(t.split_whitespace().next().unwrap_or("")).is_some() {
            return crate::thumbs::split_exec(&t);
        }
    }
    for t in ["xdg-terminal-exec", "kitty", "foot", "ghostty", "alacritty", "wezterm", "konsole", "gnome-terminal", "ptyxis", "xfce4-terminal", "xterm"] {
        if util::which(t).is_some() {
            return vec![t.to_string()];
        }
    }
    Vec::new()
}

fn launch(app: &App, files: &[PathBuf], terminal: &str) -> Result<(), String> {
    let cwd = files.first().and_then(|f| f.parent()).map(Path::to_path_buf);
    for mut argv in commands(app, files) {
        if app.terminal {
            let mut t = terminal_argv(terminal);
            if t.is_empty() {
                return Err("noterminal".into());
            }
            t.push("-e".into());
            t.append(&mut argv);
            argv = t;
        }
        util::spawn_detached(&argv, cwd.as_deref()).map_err(|e| e.to_string())?;
    }
    Ok(())
}

pub fn open(ctx: &Ctx, req: &Value) -> Result<Value, String> {
    let files: Vec<PathBuf> = req["paths"].as_array().into_iter().flatten().filter_map(|p| p.as_str()).map(PathBuf::from).collect();
    let terminal = req["terminal"].as_str().unwrap_or("");
    let apps = all();
    if let Some(id) = req["app"].as_str().filter(|s| !s.is_empty()) {
        let app = apps.get(id).ok_or("noapp")?;
        launch(app, &files, terminal)?;
        return Ok(json!({"app": id}));
    }
    // Each file with its own type's default, files sharing an app opened together.
    let mut groups: Vec<(String, Vec<PathBuf>)> = Vec::new();
    let mut leftovers = Vec::new();
    for f in &files {
        let name = util::name_of(f);
        if name.ends_with(".desktop") {
            if let Some(app) = parse(f, name.clone(), &locale_keys()) {
                launch(&app, &[], terminal)?;
                continue;
            }
        }
        let meta = fs::metadata(f).ok();
        let mime = if meta.as_ref().map(|m| m.is_dir()).unwrap_or(false) { "inode/directory".to_string() } else { ctx.mime.of_file(f, &name, meta.map(|m| m.len()).unwrap_or(1)) };
        match for_mime(ctx, &mime, &apps).0 {
            Some(id) => match groups.iter_mut().find(|(g, _)| *g == id) {
                Some((_, list)) => list.push(f.clone()),
                None => groups.push((id, vec![f.clone()])),
            },
            None => leftovers.push(f.clone()),
        }
    }
    for (id, list) in &groups {
        launch(&apps[id], list, terminal)?;
    }
    if !leftovers.is_empty() {
        if let Some(f) = leftovers.first() {
            // Nothing claims the type: xdg-open may know a portal or a handler we do not.
            util::spawn_detached(&["xdg-open".into(), f.to_string_lossy().into_owned()], f.parent()).map_err(|e| e.to_string())?;
        }
        if leftovers.len() > 1 {
            return Err("noapp".into());
        }
    }
    Ok(json!({}))
}

pub fn set_default(req: &Value) -> Result<Value, String> {
    let mime = req["mime"].as_str().ok_or("nomime")?;
    let app = req["app"].as_str().ok_or("noapp")?;
    let file = util::config_home().join("mimeapps.list");
    let text = fs::read_to_string(&file).unwrap_or_default();
    let mut out = String::new();
    let mut section = String::new();
    let mut written = false;
    let mut saw_defaults = false;
    for line in text.lines() {
        let t = line.trim();
        if t.starts_with('[') {
            if section == "[Default Applications]" && !written {
                out.push_str(&format!("{mime}={app};\n"));
                written = true;
            }
            section = t.to_string();
            saw_defaults |= t == "[Default Applications]";
            out.push_str(line);
            out.push('\n');
            continue;
        }
        if section == "[Default Applications]" && t.split_once('=').map(|(k, _)| k == mime).unwrap_or(false) {
            if !written {
                out.push_str(&format!("{mime}={app};\n"));
                written = true;
            }
            continue;
        }
        out.push_str(line);
        out.push('\n');
    }
    if !written {
        if !saw_defaults {
            out.push_str("\n[Default Applications]\n");
        }
        out.push_str(&format!("{mime}={app};\n"));
    }
    if let Some(dir) = file.parent() {
        let _ = fs::create_dir_all(dir);
    }
    let tmp = file.with_extension("inir-tmp");
    fs::write(&tmp, out).map_err(|e| e.to_string())?;
    fs::rename(&tmp, &file).map_err(|e| e.to_string())?;
    Ok(json!({}))
}

pub fn terminal(req: &Value) -> Result<Value, String> {
    let dir = PathBuf::from(req["dir"].as_str().unwrap_or(""));
    let mut argv = terminal_argv(req["terminal"].as_str().unwrap_or(""));
    if argv.is_empty() {
        return Err("noterminal".into());
    }
    if let Some(cmd) = req["command"].as_array() {
        argv.push("-e".into());
        argv.extend(cmd.iter().filter_map(|c| c.as_str()).map(str::to_string));
    }
    util::spawn_detached(&argv, Some(&dir)).map_err(|e| e.to_string())?;
    Ok(json!({}))
}

// The desktop's wallpaper: the running iNiR shell sets it over its IPC, called with the runtime this app runs on.
pub fn wallpaper(req: &Value) -> Result<Value, String> {
    let path = req["path"].as_str().unwrap_or("");
    let shell = fs::canonicalize(util::config_home().join("quickshell/inir")).map_err(|_| "noinir")?;
    let qs = util::env_path("INIR_FILES_QS")
        .or_else(|| Some(util::data_home().join("inir/runtime/current/bin/qs")).filter(|p| p.is_file()))
        .or_else(|| util::which("qs"))
        .ok_or("noinir")?;
    let (ok, _) = util::run_status(&qs.to_string_lossy(), &["-p", &shell.to_string_lossy(), "ipc", "call", "wallpaperSelector", "set", path]);
    if ok { Ok(json!({})) } else { Err("noinir".into()) }
}

pub fn run(req: &Value) -> Result<Value, String> {
    let path = PathBuf::from(req["path"].as_str().unwrap_or(""));
    if req["terminal"].as_bool().unwrap_or(false) {
        return terminal(&json!({"dir": path.parent().map(|p| p.to_string_lossy().into_owned()), "terminal": req["terminalCommand"], "command": [path.to_string_lossy()]}));
    }
    util::spawn_detached(&[path.to_string_lossy().into_owned()], path.parent()).map_err(|e| e.to_string())?;
    Ok(json!({}))
}

// The clipboard: files go out as text/uri-list, which every file manager and chooser reads. A cut is remembered by the
// interface, so a paste moves them.

pub fn clip_set(req: &Value) -> Result<Value, String> {
    use std::io::Write;
    use std::process::{Command, Stdio};
    let uris: Vec<String> = req["paths"].as_array().into_iter().flatten().filter_map(|p| p.as_str()).map(|p| util::uri(Path::new(p))).collect();
    let (mime, body) = match req["text"].as_str() {
        Some(t) => ("text/plain;charset=utf-8", t.to_string()),
        None => ("text/uri-list", uris.join("\r\n") + "\r\n"),
    };
    let mut child = Command::new("wl-copy").args(["--type", mime]).stdin(Stdio::piped()).stdout(Stdio::null()).stderr(Stdio::null()).spawn().map_err(|_| "nowlcopy")?;
    child.stdin.take().unwrap().write_all(body.as_bytes()).map_err(|e| e.to_string())?;
    // wl-copy forks to serve the selection; the first process exits at once.
    std::thread::spawn(move || {
        let _ = child.wait();
    });
    Ok(json!({}))
}

pub fn clip_get() -> Result<Value, String> {
    let types = util::run_out("wl-paste", &["--list-types"], 1500).unwrap_or_default();
    let has = |t: &str| types.lines().any(|l| l.trim() == t);
    if has("x-special/gnome-copied-files") {
        if let Some(body) = util::run_out("wl-paste", &["-n", "-t", "x-special/gnome-copied-files"], 1500) {
            let mut lines = body.lines();
            let cut = lines.next().map(|l| l.trim() == "cut").unwrap_or(false);
            let paths: Vec<String> = lines.filter_map(|l| util::path_from_uri(l.trim())).map(|p| p.to_string_lossy().into_owned()).collect();
            return Ok(json!({"paths": paths, "cut": cut, "types": types.lines().collect::<Vec<_>>()}));
        }
    }
    if has("text/uri-list") {
        let body = util::run_out("wl-paste", &["-n", "-t", "text/uri-list"], 1500).unwrap_or_default();
        let paths: Vec<String> = body.lines().filter(|l| !l.starts_with('#')).filter_map(|l| util::path_from_uri(l.trim())).map(|p| p.to_string_lossy().into_owned()).collect();
        return Ok(json!({"paths": paths, "cut": false, "types": types.lines().collect::<Vec<_>>()}));
    }
    let image = types.lines().find(|l| l.starts_with("image/")).map(str::to_string);
    let text = has("text/plain;charset=utf-8") || has("text/plain") || has("UTF8_STRING");
    Ok(json!({"paths": [], "cut": false, "image": image, "text": text, "types": types.lines().collect::<Vec<_>>()}))
}

/// What the clipboard holds that is not files, saved as a new file: a picture as itself, text as a .txt.
pub fn clip_save(req: &Value) -> Result<Value, String> {
    let dir = PathBuf::from(req["dir"].as_str().unwrap_or(""));
    let mime = req["mime"].as_str().unwrap_or("text/plain");
    let base = req["name"].as_str().unwrap_or("Pasted");
    let ext = match mime { "image/png" => "png", "image/jpeg" => "jpg", "image/webp" => "webp", "image/gif" => "gif", "image/bmp" => "bmp", _ => "txt" };
    let path = util::free_name(&dir, &format!("{base}.{ext}"));
    let out = std::process::Command::new("wl-paste").args(["-n", "-t", mime]).output().map_err(|e| e.to_string())?;
    if !out.status.success() || out.stdout.is_empty() {
        return Err("empty".into());
    }
    fs::write(&path, &out.stdout).map_err(|e| crate::list::error_code(&e))?;
    Ok(json!({"path": path.to_string_lossy()}))
}
