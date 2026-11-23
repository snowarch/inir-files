// The freedesktop shared-mime-info database, read once: globs by name, a few magic numbers for names without a hint,
// the type tree (text/x-python is a text/plain), the icon each type asks for and its localised description.

use std::collections::HashMap;
use std::fs;
use std::io::Read;
use std::path::Path;
use std::sync::Mutex;

pub struct MimeDb {
    literal: HashMap<String, (u32, String)>,
    suffix: HashMap<String, (u32, String)>,
    // Globs other than "*.ext" and literal names: (weight, type, pattern, case sensitive).
    complex: Vec<(u32, String, String, bool)>,
    aliases: HashMap<String, String>,
    parents: HashMap<String, Vec<String>>,
    generic: HashMap<String, String>,
    icons: HashMap<String, String>,
    comments: Mutex<HashMap<String, String>>,
    lang: (String, String),
}

fn lines(name: &str) -> Vec<String> {
    let mut out = Vec::new();
    // Lowest priority first: the user's own database overrides the system's.
    for dir in crate::util::data_dirs().iter().rev() {
        if let Ok(text) = fs::read_to_string(dir.join("mime").join(name)) {
            out.extend(text.lines().filter(|l| !l.starts_with('#') && !l.trim().is_empty()).map(str::to_string));
        }
    }
    out
}

fn glob_match(pattern: &[char], name: &[char]) -> bool {
    match (pattern.first(), name.first()) {
        (None, None) => true,
        (Some('*'), _) => glob_match(&pattern[1..], name) || (!name.is_empty() && glob_match(pattern, &name[1..])),
        (Some('?'), Some(_)) => glob_match(&pattern[1..], &name[1..]),
        (Some('['), Some(c)) => {
            let Some(end) = pattern.iter().position(|&p| p == ']') else { return false };
            let set = &pattern[1..end];
            let (negate, set) = if set.first() == Some(&'!') { (true, &set[1..]) } else { (false, set) };
            let mut hit = false;
            let mut i = 0;
            while i < set.len() {
                if i + 2 < set.len() && set[i + 1] == '-' {
                    hit |= set[i] <= *c && *c <= set[i + 2];
                    i += 3;
                } else {
                    hit |= set[i] == *c;
                    i += 1;
                }
            }
            hit != negate && glob_match(&pattern[end + 1..], &name[1..])
        }
        (Some(p), Some(c)) => p == c && glob_match(&pattern[1..], &name[1..]),
        _ => false,
    }
}

impl MimeDb {
    pub fn load() -> Self {
        let mut db = MimeDb {
            literal: HashMap::new(),
            suffix: HashMap::new(),
            complex: Vec::new(),
            aliases: HashMap::new(),
            parents: HashMap::new(),
            generic: HashMap::new(),
            icons: HashMap::new(),
            comments: Mutex::new(HashMap::new()),
            lang: language(),
        };
        for line in lines("globs2") {
            let mut parts = line.splitn(4, ':');
            let (Some(w), Some(mime), Some(glob)) = (parts.next(), parts.next(), parts.next()) else { continue };
            let weight: u32 = w.parse().unwrap_or(50);
            let cs = parts.next().map(|f| f.contains("cs")).unwrap_or(false);
            if glob == "__NOGLOBS__" {
                continue;
            }
            let wild = |s: &str| s.contains(['*', '?', '[']);
            if let Some(ext) = glob.strip_prefix("*.").filter(|e| !wild(e) && !cs) {
                let key = ext.to_lowercase();
                if db.suffix.get(&key).map(|(old, _)| weight > *old).unwrap_or(true) {
                    db.suffix.insert(key, (weight, mime.to_string()));
                }
            } else if !wild(glob) {
                let key = if cs { glob.to_string() } else { glob.to_lowercase() };
                db.literal.insert(key, (weight, mime.to_string()));
            } else {
                db.complex.push((weight, mime.to_string(), glob.to_string(), cs));
            }
        }
        db.complex.sort_by(|a, b| b.0.cmp(&a.0));
        for line in lines("aliases") {
            if let Some((a, b)) = line.split_once(' ') {
                db.aliases.insert(a.to_string(), b.to_string());
            }
        }
        for line in lines("subclasses") {
            if let Some((a, b)) = line.split_once(' ') {
                db.parents.entry(a.to_string()).or_default().push(b.to_string());
            }
        }
        for line in lines("generic-icons") {
            if let Some((a, b)) = line.split_once(':') {
                db.generic.insert(a.to_string(), b.to_string());
            }
        }
        for line in lines("icons") {
            if let Some((a, b)) = line.split_once(':') {
                db.icons.insert(a.to_string(), b.to_string());
            }
        }
        db
    }

    pub fn unalias<'a>(&'a self, mime: &'a str) -> &'a str {
        self.aliases.get(mime).map(String::as_str).unwrap_or(mime)
    }

    /// The type a name says it is, if it says one.
    pub fn by_name(&self, name: &str) -> Option<String> {
        if let Some((_, m)) = self.literal.get(name).or_else(|| self.literal.get(&name.to_lowercase())) {
            return Some(m.clone());
        }
        let lower = name.to_lowercase();
        // Longest suffix first: "a.tar.gz" is a compressed tarball before it is a gzip file.
        let mut at = 0;
        while let Some(dot) = lower[at..].find('.') {
            let ext = &lower[at + dot + 1..];
            if let Some((_, m)) = self.suffix.get(ext) {
                return Some(m.clone());
            }
            at += dot + 1;
        }
        let chars: Vec<char> = name.chars().collect();
        let lower_chars: Vec<char> = lower.chars().collect();
        for (_, mime, pattern, cs) in &self.complex {
            let p: Vec<char> = if *cs { pattern.chars().collect() } else { pattern.to_lowercase().chars().collect() };
            if glob_match(&p, if *cs { &chars } else { &lower_chars }) {
                return Some(mime.clone());
            }
        }
        None
    }

    /// The type of a regular file: its name, else its first bytes.
    pub fn of_file(&self, path: &Path, name: &str, size: u64) -> String {
        if let Some(m) = self.by_name(name) {
            return m;
        }
        if size == 0 {
            return "application/x-zerosize".into();
        }
        sniff(path)
    }

    pub fn is_a(&self, mime: &str, ancestor: &str) -> bool {
        let mime = self.unalias(mime);
        if mime == ancestor {
            return true;
        }
        let mut seen = 0;
        let mut stack = vec![mime.to_string()];
        while let Some(m) = stack.pop() {
            seen += 1;
            if seen > 32 {
                break;
            }
            if m == ancestor {
                return true;
            }
            if let Some(ps) = self.parents.get(&m) {
                stack.extend(ps.iter().cloned());
            }
            // Implicit parents: every text/* is a text/plain, everything is an application/octet-stream.
            if m.starts_with("text/") && m != "text/plain" {
                stack.push("text/plain".into());
            }
        }
        false
    }

    /// The type and its ancestors, nearest first.
    pub fn lineage(&self, mime: &str) -> Vec<String> {
        let mut out = vec![self.unalias(mime).to_string()];
        let mut i = 0;
        while i < out.len() && out.len() < 16 {
            let m = out[i].clone();
            for p in self.parents.get(&m).into_iter().flatten() {
                if !out.contains(p) {
                    out.push(p.clone());
                }
            }
            if m.starts_with("text/") && m != "text/plain" && !out.iter().any(|x| x == "text/plain") {
                out.push("text/plain".into());
            }
            i += 1;
        }
        out
    }

    /// (icon, generic icon) names for the icon theme.
    pub fn icons(&self, mime: &str) -> (String, String) {
        let icon = self.icons.get(mime).cloned().unwrap_or_else(|| mime.replace('/', "-"));
        let generic = self.generic.get(mime).cloned().unwrap_or_else(|| {
            let top = mime.split('/').next().unwrap_or("application");
            match top {
                "text" | "image" | "video" | "audio" | "font" => format!("{top}-x-generic"),
                _ => "application-x-generic".into(),
            }
        });
        (icon, generic)
    }

    /// What a person calls the type: "PNG image", "imagen PNG". An alias reads its type's words, a type the database
    /// does not describe reads its nearest ancestor's ("Python script" falls back to "plain text"), and a type with
    /// neither is "unknown", never blank.
    pub fn comment(&self, mime: &str) -> String {
        if let Some(c) = self.comments.lock().unwrap().get(mime) {
            return c.clone();
        }
        let read = |m: &str| {
            crate::util::data_dirs().iter().find_map(|dir| {
                let xml = fs::read_to_string(dir.join("mime").join(format!("{m}.xml"))).ok()?;
                Some(pick_comment(&xml, &self.lang)).filter(|c| !c.is_empty())
            })
        };
        let mut lineage = self.lineage(mime);
        lineage.push("application/octet-stream".into());
        let found = lineage.iter().find_map(|m| read(m)).unwrap_or_default();
        self.comments.lock().unwrap().insert(mime.to_string(), found.clone());
        found
    }

    /// What the file is, in the words the interface groups by.
    pub fn kind(&self, mime: &str) -> &'static str {
        let m = self.unalias(mime);
        let top = m.split('/').next().unwrap_or("");
        if m == "inode/directory" {
            return "folder";
        }
        if ARCHIVES.contains(&m) {
            return "archive";
        }
        if m == "application/x-iso9660-image" || m == "application/x-raw-disk-image" || m == "application/x-cd-image" {
            return "disk";
        }
        if m == "application/pdf" || m == "application/postscript" {
            return "pdf";
        }
        if m == "application/x-desktop" || m == "application/vnd.appimage" || m == "application/x-iso9660-appimage" {
            return "app";
        }
        if m == "application/epub+zip" || m.starts_with("application/vnd.oasis.opendocument") || m.starts_with("application/vnd.openxmlformats")
            || m == "application/msword" || m == "application/vnd.ms-excel" || m == "application/vnd.ms-powerpoint" || m == "application/rtf"
        {
            return "document";
        }
        match top {
            "image" => return "image",
            "video" => return "video",
            "audio" => return "audio",
            "font" => return "font",
            _ => {}
        }
        if m.starts_with("application/x-font") || m == "application/vnd.ms-opentype" {
            return "font";
        }
        if m == "application/x-executable" || m == "application/x-pie-executable" || m == "application/x-sharedlib" {
            return "executable";
        }
        if PROSE.contains(&m) {
            return "text";
        }
        if self.is_a(m, "text/plain") || m == "application/json" || m == "application/xml" || m == "application/x-shellscript"
            || m == "application/javascript" || m == "application/toml" || m == "application/x-yaml"
        {
            return "code";
        }
        "file"
    }
}

// Text people read as it is, not a language: it shows as lines, not as code.
const PROSE: &[&str] = &[
    "text/plain", "text/markdown", "application/x-zerosize", "text/csv", "text/tab-separated-values", "text/x-todo-txt",
    "text/x-log", "text/x-readme", "text/x-changelog", "text/x-copying", "text/x-authors", "text/x-install", "text/x-credits",
    "text/vtt", "application/x-subrip", "text/x-ssa", "text/x-nfo", "text/x-txt2tags", "text/x-rst", "text/x-org",
];

pub const ARCHIVES: &[&str] = &[
    "application/zip", "application/x-tar", "application/x-compressed-tar", "application/x-bzip-compressed-tar",
    "application/x-bzip2-compressed-tar", "application/x-xz-compressed-tar", "application/x-zstd-compressed-tar",
    "application/x-lzma-compressed-tar", "application/x-lz4-compressed-tar", "application/x-7z-compressed",
    "application/vnd.rar", "application/x-rar", "application/x-rar-compressed", "application/gzip", "application/x-gzip",
    "application/x-bzip", "application/x-bzip2", "application/x-xz", "application/zstd", "application/x-zstd",
    "application/x-lzma", "application/x-cpio", "application/x-archive", "application/java-archive",
    "application/vnd.debian.binary-package", "application/x-rpm", "application/x-arj", "application/x-lha",
    "application/vnd.ms-cab-compressed", "application/x-xar", "application/x-zstd-compressed-tar",
];

fn language() -> (String, String) {
    let raw = ["LC_ALL", "LC_MESSAGES", "LANG"].iter().find_map(|k| std::env::var(k).ok().filter(|v| !v.is_empty())).unwrap_or_default();
    let full = raw.split(['.', '@']).next().unwrap_or("").to_string();
    let short = full.split('_').next().unwrap_or("").to_string();
    (full, short)
}

fn pick_comment(xml: &str, lang: &(String, String)) -> String {
    let mut plain = String::new();
    let mut short = String::new();
    let mut rest = xml;
    while let Some(at) = rest.find("<comment") {
        rest = &rest[at + 8..];
        let Some(close) = rest.find('>') else { break };
        let attrs = &rest[..close];
        let Some(end) = rest.find("</comment>") else { break };
        let text = unescape(&rest[close + 1..end]);
        let tag = attrs.split("xml:lang=\"").nth(1).and_then(|s| s.split('"').next()).unwrap_or("");
        if tag.is_empty() {
            if plain.is_empty() {
                plain = text;
            }
        } else if !lang.0.is_empty() && tag == lang.0 {
            return text;
        } else if tag == lang.1 && short.is_empty() {
            short = text;
        }
        rest = &rest[end..];
    }
    if short.is_empty() { plain } else { short }
}

fn unescape(s: &str) -> String {
    s.replace("&lt;", "<").replace("&gt;", ">").replace("&quot;", "\"").replace("&apos;", "'").replace("&amp;", "&")
}

/// What an ELF file is. A program built as PIE is a shared object (e_type 3) like a library; the interpreter it asks
/// for (a PT_INTERP program header) is what makes it a program, as file(1) tells them apart.
fn elf(b: &[u8]) -> &'static str {
    let wide = b.get(4) == Some(&2);
    let little = b.get(5) != Some(&2);
    let num = |at: usize, len: usize| -> Option<u64> {
        let s = b.get(at..at + len)?;
        Some(if little { s.iter().rev().fold(0, |n, &x| n << 8 | x as u64) } else { s.iter().fold(0, |n, &x| n << 8 | x as u64) })
    };
    let interp = || -> Option<bool> {
        let (off, size, count) = if wide { (num(0x20, 8)?, num(0x36, 2)?, num(0x38, 2)?) } else { (num(0x1c, 4)?, num(0x2a, 2)?, num(0x2c, 2)?) };
        // The headers past the bytes read are not looked at: a program puts them first, right after the ELF header.
        Some((0..count).map(|i| (off + i * size) as usize).take_while(|&at| at + 4 <= b.len()).any(|at| num(at, 4) == Some(3)))
    };
    match num(16, 2) {
        Some(1) => "application/x-object",
        Some(3) if interp() != Some(true) => "application/x-sharedlib",
        Some(4) => "application/x-core",
        _ => "application/x-executable",
    }
}

/// A file without a name that says what it is, told by its first bytes.
fn sniff(path: &Path) -> String {
    let mut head = [0u8; 512];
    let n = fs::File::open(path).and_then(|mut f| f.read(&mut head)).unwrap_or(0);
    let b = &head[..n];
    let starts = |m: &[u8]| b.starts_with(m);
    let mime = if starts(b"\x7fELF") {
        elf(b)
    } else if starts(b"#!") {
        let line = String::from_utf8_lossy(&b[..b.iter().position(|&c| c == b'\n').unwrap_or(b.len())]).to_string();
        if line.contains("python") {
            "text/x-python3"
        } else if line.contains("node") {
            "application/javascript"
        } else if line.contains("perl") {
            "application/x-perl"
        } else {
            "application/x-shellscript"
        }
    } else if starts(b"%PDF") {
        "application/pdf"
    } else if starts(b"\x89PNG") {
        "image/png"
    } else if starts(b"\xff\xd8\xff") {
        "image/jpeg"
    } else if starts(b"GIF8") {
        "image/gif"
    } else if n >= 12 && &b[..4] == b"RIFF" && &b[8..12] == b"WEBP" {
        "image/webp"
    } else if starts(b"PK\x03\x04") {
        "application/zip"
    } else if starts(b"7z\xbc\xaf\x27\x1c") {
        "application/x-7z-compressed"
    } else if starts(b"\x1f\x8b") {
        "application/gzip"
    } else if starts(b"\x28\xb5\x2f\xfd") {
        "application/zstd"
    } else if starts(b"\xfd7zXZ") {
        "application/x-xz"
    } else if starts(b"Rar!") {
        "application/vnd.rar"
    } else if starts(b"OggS") {
        "audio/ogg"
    } else if starts(b"fLaC") {
        "audio/flac"
    } else if starts(b"ID3") {
        "audio/mpeg"
    } else if n >= 12 && &b[4..8] == b"ftyp" {
        "video/mp4"
    } else if starts(b"\x1a\x45\xdf\xa3") {
        "video/x-matroska"
    } else if starts(b"SQLite format 3") {
        "application/vnd.sqlite3"
    } else if !b.contains(&0) && (std::str::from_utf8(b).is_ok() || n == 512) {
        "text/plain"
    } else {
        "application/octet-stream"
    };
    mime.to_string()
}

#[cfg(test)]
mod tests {
    use super::*;

    // A 64-bit little-endian ELF header of the given e_type, its program headers right after it.
    fn elf_head(e_type: u8, headers: &[u32]) -> Vec<u8> {
        let mut b = vec![0u8; 64 + 56 * headers.len()];
        b[..6].copy_from_slice(b"\x7fELF\x02\x01");
        b[16] = e_type;
        b[0x20] = 64;
        b[0x36] = 56;
        b[0x38] = headers.len() as u8;
        for (i, t) in headers.iter().enumerate() {
            b[64 + 56 * i..68 + 56 * i].copy_from_slice(&t.to_le_bytes());
        }
        b
    }

    #[test]
    fn elf_programs_and_libraries() {
        assert_eq!(elf(&elf_head(2, &[1])), "application/x-executable");
        assert_eq!(elf(&elf_head(3, &[6, 3, 1])), "application/x-executable");
        assert_eq!(elf(&elf_head(3, &[1, 2])), "application/x-sharedlib");
        assert_eq!(elf(&elf_head(1, &[])), "application/x-object");
    }

    #[test]
    fn every_type_has_words() {
        let db = MimeDb::load();
        // An alias reads its type's words; a type with none of its own, its parent's.
        assert_eq!(db.comment("application/x-shellscript"), db.comment("text/x-shellscript"));
        assert!(!db.comment("application/x-shellscript").is_empty());
        assert!(!db.comment("application/x-made-up-type").is_empty());
    }

    #[test]
    fn globs() {
        let db = MimeDb::load();
        assert_eq!(db.by_name("a.PNG").as_deref(), Some("image/png"));
        assert_eq!(db.by_name("x.tar.gz").as_deref(), Some("application/x-compressed-tar"));
        assert_eq!(db.by_name("Makefile").as_deref(), Some("text/x-makefile"));
        assert!(db.is_a("text/x-python3", "text/plain"));
        assert_eq!(db.kind("image/png"), "image");
        assert_eq!(db.kind("application/x-compressed-tar"), "archive");
        assert_eq!(db.icons("image/png").0, "image-png");
        assert!(!db.comment("image/png").is_empty());
        assert!(glob_match(&"*.[ch]".chars().collect::<Vec<_>>(), &"main.c".chars().collect::<Vec<_>>()));
    }
}
