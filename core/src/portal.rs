// org.freedesktop.impl.portal.FileChooser backend on the session bus: lets Discord, Firefox, Chrome, Electron and
// other Wayland apps open iNiR Files for Open / Save / Select folder dialogs.
// Also provides portal_get / portal_set so Settings can enable or disable it in one click (no root needed), backing up
// and cleanly restoring the user's previous FileChooser portal value on disable.

use crate::util;
use crate::Ctx;
use serde_json::{json, Value};
use std::collections::HashMap;
use std::fs;
use std::future::Future;
use std::path::{Path, PathBuf};
use std::pin::Pin;
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::{Arc, Mutex};
use std::task::{Context, Poll, Waker};
use zbus::fdo::RequestNameFlags;
use zbus::zvariant::{OwnedObjectPath, OwnedValue, Value as ZValue};
use zbus::{connection, interface};

static NEXT_TOKEN: AtomicU64 = AtomicU64::new(1);

#[derive(Clone)]
pub struct ChooserReply {
    pub ok: bool,
    pub paths: Vec<String>,
    pub filter_index: Option<usize>,
}

struct SlotState {
    value: Option<ChooserReply>,
    waker: Option<Waker>,
}

#[derive(Clone)]
struct Slot(Arc<Mutex<SlotState>>);

impl Slot {
    fn new() -> Self {
        Self(Arc::new(Mutex::new(SlotState { value: None, waker: None })))
    }
    fn resolve(&self, reply: ChooserReply) {
        let mut s = self.0.lock().unwrap();
        if s.value.is_some() {
            return;
        }
        s.value = Some(reply);
        if let Some(w) = s.waker.take() {
            w.wake();
        }
    }
}

impl Future for Slot {
    type Output = ChooserReply;
    fn poll(self: Pin<&mut Self>, cx: &mut Context<'_>) -> Poll<Self::Output> {
        let mut s = self.0.lock().unwrap();
        if let Some(v) = s.value.clone() {
            Poll::Ready(v)
        } else {
            s.waker = Some(cx.waker().clone());
            Poll::Pending
        }
    }
}

#[derive(Default)]
pub struct Registry {
    pending: Mutex<HashMap<String, Slot>>,
}

impl Registry {
    fn register(&self, token: &str) -> Slot {
        let slot = Slot::new();
        self.pending.lock().unwrap().insert(token.to_string(), slot.clone());
        slot
    }
    fn take(&self, token: &str) -> Option<Slot> {
        self.pending.lock().unwrap().remove(token)
    }
    pub fn answer(&self, req: &Value) -> Result<Value, String> {
        let token = req["token"].as_str().unwrap_or("");
        let ok = req["ok"].as_bool().unwrap_or(false);
        let paths: Vec<String> = req["paths"]
            .as_array()
            .into_iter()
            .flatten()
            .filter_map(|v| v.as_str().map(str::to_string))
            .collect();
        let filter_index = req["filterIndex"].as_i64().and_then(|i| usize::try_from(i).ok());
        if let Some(slot) = self.take(token) {
            slot.resolve(ChooserReply { ok, paths, filter_index });
        }
        Ok(json!({}))
    }
}

// Per-request cancel handle served at the portal's request object path.
struct PortalRequest {
    ctx: Arc<Ctx>,
    token: String,
    slot: Slot,
}

#[interface(name = "org.freedesktop.impl.portal.Request")]
impl PortalRequest {
    async fn close(&self) {
        self.ctx.portal.take(&self.token);
        self.slot.resolve(ChooserReply { ok: false, paths: Vec::new(), filter_index: None });
        self.ctx.out.event("chooser_cancel", json!({"token": self.token}));
    }
}

type FilterSpec = (String, Vec<(u32, String)>);

fn bytes_option(options: &HashMap<String, OwnedValue>, key: &str) -> Option<String> {
    let v = options.get(key)?;
    let bytes: Vec<u8> = v.try_clone().ok()?.try_into().ok()?;
    let trimmed = bytes.split(|&b| b == 0).next().unwrap_or(&bytes);
    let s = String::from_utf8_lossy(trimmed).trim().to_string();
    (!s.is_empty()).then_some(s)
}

fn str_option(options: &HashMap<String, OwnedValue>, key: &str) -> Option<String> {
    let v = options.get(key)?;
    let s: String = v.try_clone().ok()?.try_into().ok()?;
    (!s.is_empty()).then_some(s)
}

fn bool_option(options: &HashMap<String, OwnedValue>, key: &str) -> bool {
    options
        .get(key)
        .and_then(|v| v.try_clone().ok())
        .and_then(|v| bool::try_from(v).ok())
        .unwrap_or(false)
}

fn filters_option(options: &HashMap<String, OwnedValue>) -> (Vec<FilterSpec>, usize) {
    let raw: Vec<FilterSpec> = options
        .get("filters")
        .and_then(|v| v.try_clone().ok())
        .and_then(|v| Vec::<FilterSpec>::try_from(v).ok())
        .unwrap_or_default();
    let cur: Option<FilterSpec> = options
        .get("current_filter")
        .and_then(|v| v.try_clone().ok())
        .and_then(|v| FilterSpec::try_from(v).ok());
    let cur_idx = cur
        .as_ref()
        .and_then(|c| raw.iter().position(|f| f == c))
        .unwrap_or(0);
    (raw, cur_idx)
}

fn save_files_names(options: &HashMap<String, OwnedValue>) -> Vec<String> {
    options
        .get("files")
        .and_then(|v| v.try_clone().ok())
        .and_then(|v| Vec::<Vec<u8>>::try_from(v).ok())
        .unwrap_or_default()
        .into_iter()
        .filter_map(|b| {
            let trimmed = b.split(|&x| x == 0).next().unwrap_or(&b);
            let s = String::from_utf8_lossy(trimmed).trim().to_string();
            (!s.is_empty()).then_some(s)
        })
        .collect()
}

struct FileChooser {
    ctx: Arc<Ctx>,
    conn: zbus::Connection,
}

impl FileChooser {
    async fn run(
        &self,
        handle: OwnedObjectPath,
        kind: &str,
        title: String,
        options: HashMap<String, OwnedValue>,
    ) -> (u32, HashMap<String, OwnedValue>) {
        let token = format!("portal-{}", NEXT_TOKEN.fetch_add(1, Ordering::Relaxed));
        let slot = self.ctx.portal.register(&token);

        let req_obj = PortalRequest { ctx: self.ctx.clone(), token: token.clone(), slot: slot.clone() };
        let _ = self.conn.object_server().at(&handle, req_obj).await;

        let accept_label = str_option(&options, "accept_label").unwrap_or_default();
        let multiple = bool_option(&options, "multiple");
        let directory = kind == "save_files" || bool_option(&options, "directory");
        let mut folder = bytes_option(&options, "current_folder").unwrap_or_default();
        let mut name = str_option(&options, "current_name").unwrap_or_default();
        if let Some(cur_file) = bytes_option(&options, "current_file") {
            let p = PathBuf::from(&cur_file);
            if folder.is_empty() {
                if let Some(par) = p.parent() {
                    folder = par.to_string_lossy().into_owned();
                }
            }
            if name.is_empty() {
                name = util::name_of(&p);
            }
        }
        let (filters, cur_filter) = filters_option(&options);
        let save_names = if kind == "save_files" { save_files_names(&options) } else { Vec::new() };
        let filters_json: Vec<Value> = filters
            .iter()
            .map(|(label, rules)| {
                let r: Vec<Value> = rules.iter().map(|(t, pat)| json!({"type": t, "pattern": pat})).collect();
                json!({"label": label, "rules": r})
            })
            .collect();

        self.ctx.out.event(
            "chooser",
            json!({
                "token": token,
                "kind": kind,
                "title": title,
                "acceptLabel": accept_label,
                "multiple": multiple,
                "directory": directory,
                "folder": folder,
                "name": name,
                "filters": filters_json,
                "currentFilter": cur_filter,
            }),
        );

        let reply = slot.await;
        let _ = self.conn.object_server().remove::<PortalRequest, _>(&handle).await;

        if !reply.ok || reply.paths.is_empty() {
            return (1, HashMap::new());
        }

        let uris: Vec<String> = if kind == "save_files" && !save_names.is_empty() {
            let dir = Path::new(&reply.paths[0]);
            save_names.iter().map(|n| util::uri(&dir.join(n))).collect()
        } else {
            reply.paths.iter().map(|p| util::uri(Path::new(p))).collect()
        };

        let mut results: HashMap<String, OwnedValue> = HashMap::new();
        if let Ok(v) = OwnedValue::try_from(ZValue::from(uris)) {
            results.insert("uris".into(), v);
        }
        if let Some(idx) = reply.filter_index {
            if let Some(f) = filters.get(idx) {
                if let Ok(v) = OwnedValue::try_from(ZValue::from(f.clone())) {
                    results.insert("current_filter".into(), v);
                }
            }
        }
        (0, results)
    }
}

#[interface(name = "org.freedesktop.impl.portal.FileChooser")]
impl FileChooser {
    async fn open_file(
        &self,
        handle: OwnedObjectPath,
        _app_id: String,
        _parent_window: String,
        title: String,
        options: HashMap<String, OwnedValue>,
    ) -> (u32, HashMap<String, OwnedValue>) {
        self.run(handle, "open", title, options).await
    }

    async fn save_file(
        &self,
        handle: OwnedObjectPath,
        _app_id: String,
        _parent_window: String,
        title: String,
        options: HashMap<String, OwnedValue>,
    ) -> (u32, HashMap<String, OwnedValue>) {
        self.run(handle, "save", title, options).await
    }

    async fn save_files(
        &self,
        handle: OwnedObjectPath,
        _app_id: String,
        _parent_window: String,
        title: String,
        options: HashMap<String, OwnedValue>,
    ) -> (u32, HashMap<String, OwnedValue>) {
        self.run(handle, "save_files", title, options).await
    }
}

pub fn start(ctx: Arc<Ctx>) {
    std::thread::spawn(move || {
        async_io::block_on(async move {
            let Ok(conn) = connection::Builder::session().and_then(|b| Ok(b)) else { return };
            let Ok(conn) = conn.build().await else { return };
            let chooser = FileChooser { ctx, conn: conn.clone() };
            if conn.object_server().at("/org/freedesktop/portal/desktop", chooser).await.is_err() {
                return;
            }
            if conn
                .request_name_with_flags(
                    "org.freedesktop.impl.portal.desktop.inir-files",
                    RequestNameFlags::AllowReplacement.into(),
                )
                .await
                .is_err()
            {
                return;
            }
            std::future::pending::<()>().await;
        });
    });
}

// ---- user-level portal registration with automatic backup & exact restore (no root required)

fn portals_conf_path() -> PathBuf {
    let dir = util::config_home().join("xdg-desktop-portal");
    let desktop = std::env::var("XDG_CURRENT_DESKTOP")
        .unwrap_or_default()
        .split(':')
        .next()
        .unwrap_or("")
        .trim()
        .to_lowercase();
    if !desktop.is_empty() {
        let specific = dir.join(format!("{desktop}-portals.conf"));
        if specific.exists() || !dir.join("portals.conf").exists() {
            return specific;
        }
    }
    dir.join("portals.conf")
}

fn user_portals_dir() -> PathBuf {
    util::data_home().join("inir/portals")
}

fn portal_dbus_service_path() -> PathBuf {
    util::data_home().join("dbus-1/services/org.freedesktop.impl.portal.desktop.inir-files.service")
}

fn systemd_dropin_path() -> PathBuf {
    util::config_home().join("systemd/user/xdg-desktop-portal.service.d/10-inir-files.conf")
}

fn backup_path() -> PathBuf {
    util::state_home().join("inir-files/portal-backup.json")
}

fn read_filechooser_value(conf: &Path) -> Option<String> {
    let text = fs::read_to_string(conf).ok()?;
    let mut in_pref = false;
    for line in text.lines() {
        let t = line.trim();
        if t.starts_with('[') {
            in_pref = t == "[preferred]";
            continue;
        }
        if in_pref {
            if let Some((k, v)) = t.split_once('=') {
                if k.trim() == "org.freedesktop.impl.portal.FileChooser" {
                    return Some(v.trim().to_string());
                }
            }
        }
    }
    None
}

fn write_filechooser_value(conf: &Path, new_value: Option<&str>) -> Result<(), String> {
    let text = fs::read_to_string(conf).unwrap_or_default();
    let mut out = String::new();
    let mut in_pref = false;
    let mut saw_pref = false;
    let mut written = false;

    for line in text.lines() {
        let t = line.trim();
        if t.starts_with('[') {
            if in_pref && !written {
                if let Some(v) = new_value {
                    out.push_str(&format!("org.freedesktop.impl.portal.FileChooser = {v}\n"));
                    written = true;
                }
            }
            in_pref = t == "[preferred]";
            saw_pref |= in_pref;
            out.push_str(line);
            out.push('\n');
            continue;
        }
        if in_pref {
            if let Some((k, _)) = t.split_once('=') {
                if k.trim() == "org.freedesktop.impl.portal.FileChooser" {
                    if !written {
                        if let Some(v) = new_value {
                            out.push_str(&format!("org.freedesktop.impl.portal.FileChooser = {v}\n"));
                        }
                        written = true;
                    }
                    continue;
                }
            }
        }
        out.push_str(line);
        out.push('\n');
    }

    if !written {
        if let Some(v) = new_value {
            if !saw_pref {
                if !out.is_empty() && !out.ends_with('\n') {
                    out.push('\n');
                }
                out.push_str("[preferred]\n");
            }
            out.push_str(&format!("org.freedesktop.impl.portal.FileChooser = {v}\n"));
        }
    }

    if let Some(parent) = conf.parent() {
        fs::create_dir_all(parent).map_err(|e| e.to_string())?;
    }
    let tmp = conf.with_extension("inir-tmp");
    fs::write(&tmp, out).map_err(|e| e.to_string())?;
    fs::rename(&tmp, conf).map_err(|e| e.to_string())?;
    Ok(())
}

fn launcher_path() -> Option<PathBuf> {
    let local = util::home().join(".local/bin/inir-files");
    if local.exists() {
        return Some(local);
    }
    let prebuilt = util::data_home().join("inir/files/current/bin/inir-files");
    if prebuilt.exists() {
        return Some(prebuilt);
    }
    util::which("inir-files")
}

fn reload_xdg_portal() {
    if util::which("systemctl").is_some() {
        let _ = util::run_status("systemctl", &["--user", "daemon-reload"]);
        let _ = util::run_status("systemctl", &["--user", "restart", "xdg-desktop-portal.service"]);
    }
}

pub fn portal_get() -> Result<Value, String> {
    let conf = portals_conf_path();
    let val = read_filechooser_value(&conf).unwrap_or_default();
    let first = val.split(';').map(str::trim).find(|s| !s.is_empty()).unwrap_or("");
    let has_portal = Path::new("/usr/share/xdg-desktop-portal/portals/inir-files.portal").is_file()
        || user_portals_dir().join("inir-files.portal").is_file();
    let enabled = first == "inir-files" && has_portal;
    Ok(json!({"enabled": enabled, "current": val}))
}

pub fn portal_set(req: &Value) -> Result<Value, String> {
    let enable = req["enable"].as_bool().unwrap_or(false);
    let conf = portals_conf_path();
    let backup = backup_path();
    let dropin = systemd_dropin_path();
    let dbus_svc = portal_dbus_service_path();
    let pdir = user_portals_dir();
    let pfile = pdir.join("inir-files.portal");

    if enable {
        let bin = launcher_path().ok_or("nolauncher")?;

        // 1. User portals dir: mirror every system *.portal so gnome/gtk/kde/umbriel stay intact, plus inir-files.portal.
        fs::create_dir_all(&pdir).map_err(|e| e.to_string())?;
        if let Ok(rd) = fs::read_dir("/usr/share/xdg-desktop-portal/portals") {
            for de in rd.flatten() {
                let name = de.file_name();
                let name_s = name.to_string_lossy();
                if !name_s.ends_with(".portal") || name_s == "inir-files.portal" {
                    continue;
                }
                let dst = pdir.join(&name);
                if dst.symlink_metadata().is_err() {
                    let _ = std::os::unix::fs::symlink(de.path(), &dst);
                }
            }
        }
        fs::write(
            &pfile,
            "[portal]\nDBusName=org.freedesktop.impl.portal.desktop.inir-files\nInterfaces=org.freedesktop.impl.portal.FileChooser;\n",
        )
        .map_err(|e| e.to_string())?;

        // 2. D-Bus activation file for the portal backend.
        if let Some(parent) = dbus_svc.parent() {
            fs::create_dir_all(parent).map_err(|e| e.to_string())?;
        }
        let svc_body = format!(
            "[D-BUS Service]\nName=org.freedesktop.impl.portal.desktop.inir-files\nExec={} --service\n",
            bin.to_string_lossy()
        );
        let tmp = dbus_svc.with_extension("inir-tmp");
        fs::write(&tmp, svc_body).map_err(|e| e.to_string())?;
        fs::rename(&tmp, &dbus_svc).map_err(|e| e.to_string())?;

        // 3. Systemd user drop-in pointing xdg-desktop-portal at our mirrored user portals dir (only if system dir lacks it).
        if !Path::new("/usr/share/xdg-desktop-portal/portals/inir-files.portal").is_file() {
            if let Some(parent) = dropin.parent() {
                fs::create_dir_all(parent).map_err(|e| e.to_string())?;
            }
            fs::write(
                &dropin,
                format!("[Service]\nEnvironment=XDG_DESKTOP_PORTAL_DIR={}\n", pdir.to_string_lossy()),
            )
            .map_err(|e| e.to_string())?;
        }

        // 4. Back up the user's exact previous FileChooser line (never overwrite backup if already set to inir-files).
        let current = read_filechooser_value(&conf);
        let already = current
            .as_deref()
            .and_then(|v| v.split(';').map(str::trim).find(|s| !s.is_empty()))
            == Some("inir-files");
        let fallback = if already {
            current
                .as_deref()
                .unwrap_or("")
                .split(';')
                .map(str::trim)
                .filter(|s| !s.is_empty() && *s != "inir-files")
                .collect::<Vec<_>>()
                .join(";")
        } else {
            if let Some(parent) = backup.parent() {
                let _ = fs::create_dir_all(parent);
            }
            let _ = fs::write(
                &backup,
                serde_json::to_string_pretty(&json!({
                    "conf": conf.to_string_lossy(),
                    "previous": current,
                }))
                .unwrap_or_default(),
            );
            current.unwrap_or_default()
        };

        let next = if fallback.is_empty() {
            "inir-files;gtk".to_string()
        } else {
            format!("inir-files;{fallback}")
        };
        write_filechooser_value(&conf, Some(&next))?;
        reload_xdg_portal();
    } else {
        // Restore the user's exact previous FileChooser value (or strip inir-files; fallback cleanly).
        let restored: Option<String> = fs::read_to_string(&backup)
            .ok()
            .and_then(|s| serde_json::from_str::<Value>(&s).ok())
            .and_then(|v| v.get("previous").and_then(|p| p.as_str()).map(str::to_string))
            .or_else(|| {
                let cur = read_filechooser_value(&conf)?;
                let rest: Vec<&str> = cur.split(';').map(str::trim).filter(|s| !s.is_empty() && *s != "inir-files").collect();
                (!rest.is_empty()).then(|| rest.join(";"))
            });
        write_filechooser_value(&conf, restored.as_deref())?;
        let _ = fs::remove_file(&backup);
        let _ = fs::remove_file(&dropin);
        let _ = fs::remove_file(&dbus_svc);
        let _ = fs::remove_file(&pfile);
        reload_xdg_portal();
    }

    portal_get()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn portals_conf_updates_and_restores_cleanly() {
        let dir = std::env::temp_dir().join(format!("inir-files-portal-test-{}", std::process::id()));
        let _ = fs::create_dir_all(&dir);
        let conf = dir.join("niri-portals.conf");
        fs::write(
            &conf,
            "[preferred]\ndefault = gnome;gtk\norg.freedesktop.impl.portal.ScreenCast = gnome\norg.freedesktop.impl.portal.FileChooser = gtk\n",
        )
        .unwrap();

        assert_eq!(read_filechooser_value(&conf).as_deref(), Some("gtk"));
        write_filechooser_value(&conf, Some("inir-files;gtk")).unwrap();
        assert_eq!(read_filechooser_value(&conf).as_deref(), Some("inir-files;gtk"));
        let body = fs::read_to_string(&conf).unwrap();
        assert!(body.contains("org.freedesktop.impl.portal.ScreenCast = gnome"));

        write_filechooser_value(&conf, Some("gtk")).unwrap();
        assert_eq!(read_filechooser_value(&conf).as_deref(), Some("gtk"));
        let _ = fs::remove_dir_all(&dir);
    }
}
