// org.freedesktop.FileManager1 on the session bus: "Show in folder" from browsers, mail and other apps. Each call
// becomes a "show" event, and the interface opens a window for it. The name is queued for, never taken: a file
// manager that holds it keeps it, and this one gets it when that one ends.

use crate::Ctx;
use serde_json::json;
use std::sync::Arc;
use zbus::{blocking::connection, fdo::RequestNameFlags, interface};

struct FileManager {
    ctx: Arc<Ctx>,
}

impl FileManager {
    fn show(&self, how: &str, uris: &[String]) {
        let paths: Vec<String> = uris.iter().filter_map(|u| path_of(u)).collect();
        if !paths.is_empty() {
            self.ctx.out.event("show", json!({"how": how, "paths": paths}));
        }
    }
}

#[interface(name = "org.freedesktop.FileManager1")]
impl FileManager {
    fn show_folders(&self, uris: Vec<String>, _startup_id: String) {
        self.show("folders", &uris)
    }
    fn show_items(&self, uris: Vec<String>, _startup_id: String) {
        self.show("items", &uris)
    }
    fn show_item_properties(&self, uris: Vec<String>, _startup_id: String) {
        self.show("properties", &uris)
    }
}

/// The local path of a file:// URI (its host dropped) or of a plain absolute path; other places are not served.
fn path_of(uri: &str) -> Option<String> {
    let path = match uri.strip_prefix("file://") {
        Some(rest) => {
            let p = &rest[rest.find('/')?..];
            String::from_utf8_lossy(&percent_encoding::percent_decode_str(p).collect::<Vec<u8>>()).into_owned()
        }
        None if uri.starts_with('/') => uri.to_string(),
        None => return None,
    };
    let trimmed = path.trim_end_matches('/');
    Some(if trimmed.is_empty() { "/".into() } else { trimmed.into() })
}

pub fn start(ctx: Arc<Ctx>) {
    std::thread::spawn(move || {
        let conn = match connection::Builder::session()
            .and_then(|b| b.serve_at("/org/freedesktop/FileManager1", FileManager { ctx }))
            .and_then(|b| b.build())
        {
            Ok(c) => c,
            // No session bus: there is nobody to serve.
            Err(_) => return,
        };
        if conn.request_name_with_flags("org.freedesktop.FileManager1", RequestNameFlags::AllowReplacement.into()).is_err() {
            return;
        }
        // The connection answers on its own thread while it lives.
        loop {
            std::thread::park();
        }
    });
}

#[cfg(test)]
mod tests {
    use super::path_of;

    #[test]
    fn paths_from_uris() {
        assert_eq!(path_of("file:///home/a/My%20File.txt").as_deref(), Some("/home/a/My File.txt"));
        assert_eq!(path_of("file://localhost/tmp/x/").as_deref(), Some("/tmp/x"));
        assert_eq!(path_of("file:///").as_deref(), Some("/"));
        assert_eq!(path_of("/tmp/%41").as_deref(), Some("/tmp/%41"));
        assert_eq!(path_of("sftp://host/tmp"), None);
        assert_eq!(path_of("file://host"), None);
    }
}
