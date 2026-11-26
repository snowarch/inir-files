// LocalSend v2.1 local network discovery, send and receive (pure Rust, HTTPS + HTTP).
// - UDP multicast discovery on 224.0.0.167:53317 with SO_REUSEADDR + SO_REUSEPORT so it coexists cleanly
//   with a running standalone LocalSend desktop app on the same machine.
// - Dual-mode TCP server (auto-detects TLS ClientHello 0x16 vs plain HTTP on the same port) serving the
//   LocalSend v2.1 REST API (/info, /register, /prepare-upload, /upload, /cancel).
// - Streaming 64 KiB upload/download with cooperative cancellation and path-traversal sanitization.

use crate::util;
use crate::Ctx;
use rustls::client::danger::{HandshakeSignatureValid, ServerCertVerified, ServerCertVerifier};
use rustls::pki_types::{CertificateDer, PrivateKeyDer, PrivatePkcs8KeyDer, ServerName, UnixTime};
use rustls::{ClientConfig, ClientConnection, DigitallySignedStruct, Error as TlsError, ServerConfig, ServerConnection, SignatureScheme, StreamOwned};
use serde_json::{json, Value};
use sha2::{Digest, Sha256};
use std::collections::HashMap;
use std::fs::{self, File};
use std::io::{BufRead, BufReader, Read, Write};
use std::net::{IpAddr, Ipv4Addr, SocketAddr, SocketAddrV4, TcpListener, TcpStream, UdpSocket};
use std::os::unix::io::{AsRawFd, FromRawFd};
use std::path::{Component, Path, PathBuf};
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::sync::{mpsc, Arc, Mutex};
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};

const MULTICAST_ADDR: Ipv4Addr = Ipv4Addr::new(224, 0, 0, 167);
const DEFAULT_PORT: u16 = 53317;
const PROTOCOL_VERSION: &str = "2.1";
const PEER_TTL_SECS: u64 = 120;

#[derive(Clone, Debug)]
pub struct Peer {
    pub fingerprint: String,
    pub alias: String,
    pub device_model: String,
    pub device_type: String,
    pub version: String,
    pub ip: String,
    pub port: u16,
    pub protocol: String,
    pub download: bool,
    pub last_seen: Instant,
}

impl Peer {
    fn to_json(&self) -> Value {
        json!({
            "fingerprint": self.fingerprint,
            "alias": self.alias,
            "deviceModel": self.device_model,
            "deviceType": self.device_type,
            "version": self.version,
            "ip": self.ip,
            "port": self.port,
            "protocol": self.protocol,
            "download": self.download,
            "age": self.last_seen.elapsed().as_secs(),
        })
    }
}

struct IncomingFile {
    file_name: String,
    token: String,
}

struct IncomingSession {
    sender_alias: String,
    dest_dir: PathBuf,
    files: HashMap<String, IncomingFile>,
    total_bytes: u64,
    received_bytes: u64,
    done_files: u64,
    total_files: u64,
    cancelled: Arc<AtomicBool>,
    created: Instant,
}

struct PendingOffer {
    tx: mpsc::Sender<Option<PathBuf>>,
}

struct Identity {
    alias: String,
    fingerprint: String,
    server_config: Arc<ServerConfig>,
    client_config: Arc<ClientConfig>,
}

struct Runtime {
    stop: Arc<AtomicBool>,
    port: u16,
    udp: Arc<UdpSocket>,
    identity: Arc<Identity>,
}

pub struct LocalSend {
    runtime: Mutex<Option<Runtime>>,
    peers: Mutex<HashMap<String, Peer>>,
    offers: Mutex<HashMap<String, PendingOffer>>,
    sessions: Mutex<HashMap<String, Arc<Mutex<IncomingSession>>>>,
    outgoing: Mutex<HashMap<String, Arc<AtomicBool>>>,
    next_id: AtomicU64,
    auto_accept: AtomicBool,
    save_dir: Mutex<PathBuf>,
    alias_override: Mutex<String>,
}

impl Default for LocalSend {
    fn default() -> Self {
        Self {
            runtime: Mutex::new(None),
            peers: Mutex::new(HashMap::new()),
            offers: Mutex::new(HashMap::new()),
            sessions: Mutex::new(HashMap::new()),
            outgoing: Mutex::new(HashMap::new()),
            next_id: AtomicU64::new(1),
            auto_accept: AtomicBool::new(false),
            save_dir: Mutex::new(default_downloads_dir()),
            alias_override: Mutex::new(String::new()),
        }
    }
}

fn default_downloads_dir() -> PathBuf {
    for (role, p) in crate::places::xdg_dirs() {
        if role == "downloads" && p.is_dir() {
            return p;
        }
    }
    let dl = util::home().join("Downloads");
    if dl.is_dir() { dl } else { util::home() }
}

fn default_alias() -> String {
    let host = fs::read_to_string("/etc/hostname")
        .ok()
        .map(|s| s.trim().to_string())
        .filter(|s| !s.is_empty())
        .unwrap_or_else(|| "iNiR Files".into());
    host
}

/// Custom TLS verifier for LAN LocalSend peers, which all use self-signed X.509 certificates.
#[derive(Debug)]
struct LanCertVerifier;

impl ServerCertVerifier for LanCertVerifier {
    fn verify_server_cert(
        &self,
        _end_entity: &CertificateDer<'_>,
        _intermediates: &[CertificateDer<'_>],
        _server_name: &ServerName<'_>,
        _ocsp_response: &[u8],
        _now: UnixTime,
    ) -> Result<ServerCertVerified, TlsError> {
        Ok(ServerCertVerified::assertion())
    }

    fn verify_tls12_signature(
        &self,
        _message: &[u8],
        _cert: &CertificateDer<'_>,
        _dss: &DigitallySignedStruct,
    ) -> Result<HandshakeSignatureValid, TlsError> {
        Ok(HandshakeSignatureValid::assertion())
    }

    fn verify_tls13_signature(
        &self,
        _message: &[u8],
        _cert: &CertificateDer<'_>,
        _dss: &DigitallySignedStruct,
    ) -> Result<HandshakeSignatureValid, TlsError> {
        Ok(HandshakeSignatureValid::assertion())
    }

    fn supported_verify_schemes(&self) -> Vec<SignatureScheme> {
        vec![
            SignatureScheme::RSA_PKCS1_SHA256,
            SignatureScheme::RSA_PKCS1_SHA384,
            SignatureScheme::RSA_PKCS1_SHA512,
            SignatureScheme::ECDSA_NISTP256_SHA256,
            SignatureScheme::ECDSA_NISTP384_SHA384,
            SignatureScheme::ED25519,
            SignatureScheme::RSA_PSS_SHA256,
            SignatureScheme::RSA_PSS_SHA384,
            SignatureScheme::RSA_PSS_SHA512,
        ]
    }
}

fn build_identity(alias: String) -> Result<Identity, String> {
    let _ = rustls::crypto::ring::default_provider().install_default();
    let certified = rcgen::generate_simple_self_signed(vec!["localhost".into(), "inir-files.local".into()])
        .map_err(|e| format!("cert: {e}"))?;
    let cert_der = certified.cert.der().to_vec();
    let key_der = certified.key_pair.serialize_der();

    let mut hasher = Sha256::new();
    hasher.update(&cert_der);
    let fingerprint = hasher.finalize().iter().map(|b| format!("{b:02X}")).collect::<String>();

    let server_config = ServerConfig::builder()
        .with_no_client_auth()
        .with_single_cert(
            vec![CertificateDer::from(cert_der)],
            PrivateKeyDer::Pkcs8(PrivatePkcs8KeyDer::from(key_der)),
        )
        .map_err(|e| format!("tls_server: {e}"))?;

    let client_config = ClientConfig::builder()
        .dangerous()
        .with_custom_certificate_verifier(Arc::new(LanCertVerifier))
        .with_no_client_auth();

    Ok(Identity {
        alias,
        fingerprint,
        server_config: Arc::new(server_config),
        client_config: Arc::new(client_config),
    })
}

/// Enumerate active non-loopback IPv4 interface addresses and netmasks on Linux via getifaddrs.
fn local_ipv4_interfaces() -> Vec<(Ipv4Addr, Ipv4Addr)> {
    let mut out = Vec::new();
    unsafe {
        let mut ifap: *mut libc::ifaddrs = std::ptr::null_mut();
        if libc::getifaddrs(&mut ifap) != 0 || ifap.is_null() {
            return out;
        }
        let mut cur = ifap;
        while !cur.is_null() {
            let ifa = &*cur;
            if !ifa.ifa_addr.is_null()
                && (*ifa.ifa_addr).sa_family as i32 == libc::AF_INET
                && (ifa.ifa_flags & libc::IFF_UP as u32) != 0
                && (ifa.ifa_flags & libc::IFF_LOOPBACK as u32) == 0
            {
                let sin = &*(ifa.ifa_addr as *const libc::sockaddr_in);
                let ip = Ipv4Addr::from(u32::from_be(sin.sin_addr.s_addr));
                let mask = if !ifa.ifa_netmask.is_null() {
                    let m = &*(ifa.ifa_netmask as *const libc::sockaddr_in);
                    Ipv4Addr::from(u32::from_be(m.sin_addr.s_addr))
                } else {
                    Ipv4Addr::new(255, 255, 255, 0)
                };
                if !ip.is_loopback() && !ip.is_unspecified() && !out.iter().any(|(a, _)| *a == ip) {
                    out.push((ip, mask));
                }
            }
            cur = ifa.ifa_next;
        }
        libc::freeifaddrs(ifap);
    }
    out
}

/// Bind a multicast-capable IPv4 UDP socket on 0.0.0.0:53317 with SO_REUSEADDR + SO_REUSEPORT
/// so we coexist cleanly with any standalone LocalSend app running on the same host.
fn bind_multicast_udp() -> Result<UdpSocket, String> {
    unsafe {
        let fd = libc::socket(libc::AF_INET, libc::SOCK_DGRAM | libc::SOCK_CLOEXEC, 0);
        if fd < 0 {
            return Err(std::io::Error::last_os_error().to_string());
        }
        let one: libc::c_int = 1;
        libc::setsockopt(fd, libc::SOL_SOCKET, libc::SO_REUSEADDR, &one as *const _ as *const libc::c_void, std::mem::size_of::<libc::c_int>() as libc::socklen_t);
        libc::setsockopt(fd, libc::SOL_SOCKET, libc::SO_REUSEPORT, &one as *const _ as *const libc::c_void, std::mem::size_of::<libc::c_int>() as libc::socklen_t);
        let mut addr: libc::sockaddr_in = std::mem::zeroed();
        addr.sin_family = libc::AF_INET as libc::sa_family_t;
        addr.sin_port = DEFAULT_PORT.to_be();
        addr.sin_addr = libc::in_addr { s_addr: 0 };
        if libc::bind(fd, &addr as *const _ as *const libc::sockaddr, std::mem::size_of::<libc::sockaddr_in>() as libc::socklen_t) != 0 {
            let err = std::io::Error::last_os_error();
            libc::close(fd);
            return Err(err.to_string());
        }
        let sock = UdpSocket::from_raw_fd(fd);
        let _ = sock.set_multicast_loop_v4(true);
        let _ = sock.set_multicast_ttl_v4(4);
        let ifaces = local_ipv4_interfaces();
        if ifaces.is_empty() {
            let _ = sock.join_multicast_v4(&MULTICAST_ADDR, &Ipv4Addr::UNSPECIFIED);
        } else {
            for (ip, _) in &ifaces {
                let _ = sock.join_multicast_v4(&MULTICAST_ADDR, ip);
            }
        }
        let _ = sock.set_read_timeout(Some(Duration::from_millis(500)));
        Ok(sock)
    }
}

fn bind_tcp_listener() -> Result<(TcpListener, u16), String> {
    for port in DEFAULT_PORT..=(DEFAULT_PORT + 16) {
        if let Ok(listener) = TcpListener::bind(SocketAddrV4::new(Ipv4Addr::UNSPECIFIED, port)) {
            let _ = listener.set_nonblocking(true);
            return Ok((listener, port));
        }
    }
    let listener = TcpListener::bind(SocketAddrV4::new(Ipv4Addr::UNSPECIFIED, 0)).map_err(|e| e.to_string())?;
    let port = listener.local_addr().map_err(|e| e.to_string())?.port();
    let _ = listener.set_nonblocking(true);
    Ok((listener, port))
}

fn info_json(id: &Identity, port: u16, announce: Option<bool>) -> Value {
    let mut v = json!({
        "alias": id.alias,
        "version": PROTOCOL_VERSION,
        "deviceModel": "Linux",
        "deviceType": "desktop",
        "fingerprint": id.fingerprint,
        "port": port,
        "protocol": "https",
        "download": false,
    });
    if let Some(a) = announce {
        v["announce"] = json!(a);
    }
    v
}

/// Sanitize a LocalSend relative file name (may contain `/` for folders) to prevent path traversal.
pub fn sanitize_rel_path(name: &str) -> Option<PathBuf> {
    if name.is_empty() || name.contains('\0') {
        return None;
    }
    let normalized = name.replace('\\', "/");
    let mut out = PathBuf::new();
    for comp in Path::new(&normalized).components() {
        match comp {
            Component::Normal(part) => {
                let s = part.to_string_lossy();
                if s.is_empty() || s == "." || s == ".." {
                    return None;
                }
                out.push(part);
            }
            Component::CurDir => {}
            Component::ParentDir | Component::RootDir | Component::Prefix(_) => return None,
        }
    }
    if out.as_os_str().is_empty() { None } else { Some(out) }
}

fn parse_query(raw: &str) -> HashMap<String, String> {
    let mut map = HashMap::new();
    for pair in raw.split('&') {
        if pair.is_empty() {
            continue;
        }
        let (k, v) = pair.split_once('=').unwrap_or((pair, ""));
        let dk = percent_encoding::percent_decode_str(k).decode_utf8_lossy().into_owned();
        let dv = percent_encoding::percent_decode_str(v).decode_utf8_lossy().into_owned();
        map.insert(dk, dv);
    }
    map
}

fn rand_token(prefix: &str, seq: u64) -> String {
    let ns = SystemTime::now().duration_since(UNIX_EPOCH).map(|d| d.as_nanos()).unwrap_or(0);
    let mut h = Sha256::new();
    h.update(format!("{prefix}:{seq}:{ns}:{}", std::process::id()).as_bytes());
    let digest = h.finalize();
    digest[..12].iter().map(|b| format!("{b:02x}")).collect()
}

impl LocalSend {
    pub fn status(&self) -> Value {
        let rt = self.runtime.lock().unwrap();
        let peers = self.peers_vec();
        let save_dir = self.save_dir.lock().unwrap().to_string_lossy().into_owned();
        match rt.as_ref() {
            Some(r) => json!({
                "running": true,
                "alias": r.identity.alias,
                "fingerprint": r.identity.fingerprint,
                "port": r.port,
                "protocol": "https",
                "autoAccept": self.auto_accept.load(Ordering::Relaxed),
                "saveDir": save_dir,
                "peers": peers,
            }),
            None => json!({
                "running": false,
                "alias": self.current_alias(),
                "fingerprint": "",
                "port": 0,
                "protocol": "https",
                "autoAccept": self.auto_accept.load(Ordering::Relaxed),
                "saveDir": save_dir,
                "peers": [],
            }),
        }
    }

    fn current_alias(&self) -> String {
        let o = self.alias_override.lock().unwrap();
        if o.trim().is_empty() { default_alias() } else { o.trim().to_string() }
    }

    pub fn peers_vec(&self) -> Vec<Value> {
        let mut map = self.peers.lock().unwrap();
        map.retain(|_, p| p.last_seen.elapsed().as_secs() < PEER_TTL_SECS);
        let mut list: Vec<&Peer> = map.values().collect();
        list.sort_by(|a, b| a.alias.to_lowercase().cmp(&b.alias.to_lowercase()).then_with(|| a.ip.cmp(&b.ip)));
        list.into_iter().map(Peer::to_json).collect()
    }

    fn emit_peers(&self, ctx: &Ctx) {
        ctx.out.event("localsend_peers", json!({"peers": self.peers_vec()}));
    }

    fn upsert_peer(&self, ctx: &Ctx, peer: Peer) {
        {
            let mut map = self.peers.lock().unwrap();
            map.insert(peer.fingerprint.clone(), peer);
        }
        self.emit_peers(ctx);
    }

    pub fn configure(&self, ctx: &Arc<Ctx>, req: &Value) -> Result<Value, String> {
        if let Some(a) = req["autoAccept"].as_bool() {
            self.auto_accept.store(a, Ordering::Relaxed);
        }
        if let Some(dir) = req["saveDir"].as_str().filter(|s| !s.is_empty()) {
            *self.save_dir.lock().unwrap() = PathBuf::from(dir);
        }
        if let Some(alias) = req["alias"].as_str() {
            *self.alias_override.lock().unwrap() = alias.trim().to_string();
            if self.runtime.lock().unwrap().is_some() {
                self.stop(ctx);
                let _ = self.start(ctx);
            }
        }
        Ok(self.status())
    }

    pub fn start(&self, ctx: &Arc<Ctx>) -> Result<Value, String> {
        {
            if self.runtime.lock().unwrap().is_some() {
                self.announce();
                return Ok(self.status());
            }
        }
        let identity = Arc::new(build_identity(self.current_alias())?);
        let (listener, port) = bind_tcp_listener()?;
        let udp = Arc::new(bind_multicast_udp().or_else(|_| {
            // Fallback ephemeral UDP socket if 53317 bind failed (rare firewall/namespace).
            let s = UdpSocket::bind(SocketAddrV4::new(Ipv4Addr::UNSPECIFIED, 0)).map_err(|e| e.to_string())?;
            let _ = s.set_read_timeout(Some(Duration::from_millis(500)));
            Ok::<UdpSocket, String>(s)
        })?);

        let stop = Arc::new(AtomicBool::new(false));
        *self.runtime.lock().unwrap() = Some(Runtime {
            stop: stop.clone(),
            port,
            udp: udp.clone(),
            identity: identity.clone(),
        });

        // TCP HTTP/HTTPS server thread.
        {
            let ctx = ctx.clone();
            let stop = stop.clone();
            let id = identity.clone();
            std::thread::spawn(move || tcp_loop(&ctx, listener, port, id, stop));
        }

        // UDP multicast receiver thread.
        {
            let ctx = ctx.clone();
            let stop = stop.clone();
            let id = identity.clone();
            let udp_rx = udp.clone();
            std::thread::spawn(move || udp_loop(&ctx, udp_rx, port, id, stop));
        }

        // Periodic multicast announcement (startup burst + every 25 s while active).
        {
            let ctx = ctx.clone();
            let stop = stop.clone();
            std::thread::spawn(move || {
                for delay in [100u64, 500, 1500] {
                    if stop.load(Ordering::Relaxed) { return; }
                    ctx.localsend.announce();
                    std::thread::sleep(Duration::from_millis(delay));
                }
                while !stop.load(Ordering::Relaxed) {
                    for _ in 0..50 {
                        if stop.load(Ordering::Relaxed) { return; }
                        std::thread::sleep(Duration::from_millis(500));
                    }
                    ctx.localsend.announce();
                    ctx.localsend.emit_peers(&ctx);
                }
            });
        }

        let st = self.status();
        ctx.out.event("localsend_status", st.clone());
        Ok(st)
    }

    pub fn stop(&self, ctx: &Ctx) {
        if let Some(rt) = self.runtime.lock().unwrap().take() {
            rt.stop.store(true, Ordering::Relaxed);
        }
        self.peers.lock().unwrap().clear();
        let pending: Vec<_> = self.offers.lock().unwrap().drain().collect();
        for (_, offer) in pending {
            let _ = offer.tx.send(None);
        }
        ctx.out.event("localsend_status", self.status());
    }

    pub fn announce(&self) {
        let (udp, payload) = {
            let guard = self.runtime.lock().unwrap();
            let Some(rt) = guard.as_ref() else { return };
            (rt.udp.clone(), info_json(&rt.identity, rt.port, Some(true)).to_string())
        };
        let target = SocketAddrV4::new(MULTICAST_ADDR, DEFAULT_PORT);
        let ifaces = local_ipv4_interfaces();
        if ifaces.is_empty() {
            let _ = udp.send_to(payload.as_bytes(), target);
        } else {
            for (ip, _) in ifaces {
                let raw = udp.as_raw_fd();
                let addr = libc::in_addr { s_addr: u32::from(ip).to_be() };
                unsafe {
                    libc::setsockopt(
                        raw,
                        libc::IPPROTO_IP,
                        libc::IP_MULTICAST_IF,
                        &addr as *const _ as *const libc::c_void,
                        std::mem::size_of::<libc::in_addr>() as libc::socklen_t,
                    );
                }
                let _ = udp.send_to(payload.as_bytes(), target);
            }
        }
    }

    /// Multicast re-announce + fast parallel /24 LAN fallback probe on port 53317.
    pub fn scan(&self, ctx: &Arc<Ctx>) -> Result<Value, String> {
        if self.runtime.lock().unwrap().is_none() {
            self.start(ctx)?;
        }
        self.announce();
        let (id, port) = {
            let guard = self.runtime.lock().unwrap();
            let Some(rt) = guard.as_ref() else { return Ok(self.status()) };
            (rt.identity.clone(), rt.port)
        };
        let ctx = ctx.clone();
        std::thread::spawn(move || {
            let ifaces = local_ipv4_interfaces();
            let mut candidates: Vec<Ipv4Addr> = Vec::new();
            for (ip, _) in &ifaces {
                let oct = ip.octets();
                for host in 1u8..=254 {
                    let cand = Ipv4Addr::new(oct[0], oct[1], oct[2], host);
                    if cand != *ip && !candidates.contains(&cand) {
                        candidates.push(cand);
                    }
                }
            }
            // Also probe localhost in case standalone LocalSend app is running on 53317 while we are on 53318+.
            if port != DEFAULT_PORT {
                probe_host(&ctx, &id, port, "127.0.0.1", DEFAULT_PORT);
            }
            // Probe in parallel chunks (32 threads, 250 ms connect timeout -> full /24 finishes in ~2 s).
            let chunk = candidates.len().div_ceil(32).max(1);
            std::thread::scope(|s| {
                for part in candidates.chunks(chunk) {
                    let ctx = &ctx;
                    let id = &id;
                    s.spawn(move || {
                        for ip in part {
                            if TcpStream::connect_timeout(&SocketAddr::V4(SocketAddrV4::new(*ip, DEFAULT_PORT)), Duration::from_millis(220)).is_ok() {
                                probe_host(ctx, id, port, &ip.to_string(), DEFAULT_PORT);
                            }
                        }
                    });
                }
            });
            ctx.out.event("localsend_scan", json!({"done": true, "peers": ctx.localsend.peers_vec()}));
        });
        Ok(json!({"scanning": true}))
    }

    pub fn probe_manual(&self, ctx: &Arc<Ctx>, host: &str, port: u16) -> Result<Value, String> {
        if self.runtime.lock().unwrap().is_none() {
            self.start(ctx)?;
        }
        let (id, our_port) = {
            let guard = self.runtime.lock().unwrap();
            let Some(rt) = guard.as_ref() else { return Err("localsend_off".into()) };
            (rt.identity.clone(), rt.port)
        };
        if probe_host(ctx, &id, our_port, host, port) {
            Ok(json!({"peers": self.peers_vec()}))
        } else {
            Err("localsend_unreachable".into())
        }
    }

    pub fn respond_offer(&self, session_id: &str, accept: bool, dest: Option<&str>) -> Result<Value, String> {
        let offer = self.offers.lock().unwrap().remove(session_id);
        let Some(offer) = offer else {
            return Err("missing".into());
        };
        let target = if accept {
            Some(dest.filter(|s| !s.is_empty()).map(PathBuf::from).unwrap_or_else(|| self.save_dir.lock().unwrap().clone()))
        } else {
            None
        };
        let _ = offer.tx.send(target);
        Ok(json!({}))
    }

    pub fn cancel_transfer(&self, id: &str) -> Result<Value, String> {
        if let Some(flag) = self.outgoing.lock().unwrap().get(id) {
            flag.store(true, Ordering::Relaxed);
        }
        if let Some(sess) = self.sessions.lock().unwrap().get(id) {
            sess.lock().unwrap().cancelled.store(true, Ordering::Relaxed);
        }
        Ok(json!({}))
    }

    pub fn send_files(&self, ctx: &Arc<Ctx>, req: &Value) -> Result<Value, String> {
        if self.runtime.lock().unwrap().is_none() {
            self.start(ctx)?;
        }
        let (id, our_port) = {
            let guard = self.runtime.lock().unwrap();
            let Some(rt) = guard.as_ref() else { return Err("localsend_off".into()) };
            (rt.identity.clone(), rt.port)
        };
        let fp = req["fingerprint"].as_str().unwrap_or("");
        let peer = if !fp.is_empty() {
            self.peers.lock().unwrap().get(fp).cloned()
        } else if let Some(ip) = req["ip"].as_str().filter(|s| !s.is_empty()) {
            Some(Peer {
                fingerprint: format!("{ip}:{}", req["port"].as_u64().unwrap_or(DEFAULT_PORT as u64)),
                alias: req["alias"].as_str().unwrap_or(ip).to_string(),
                device_model: String::new(),
                device_type: "desktop".into(),
                version: PROTOCOL_VERSION.into(),
                ip: ip.to_string(),
                port: req["port"].as_u64().unwrap_or(DEFAULT_PORT as u64) as u16,
                protocol: req["protocol"].as_str().unwrap_or("https").to_string(),
                download: false,
                last_seen: Instant::now(),
            })
        } else {
            None
        };
        let Some(peer) = peer else { return Err("localsend_nopeer".into()) };
        let raw_paths: Vec<PathBuf> = req["paths"]
            .as_array()
            .into_iter()
            .flatten()
            .filter_map(|v| v.as_str())
            .map(PathBuf::from)
            .collect();
        if raw_paths.is_empty() {
            return Err("missing".into());
        }
        let pin = req["pin"].as_str().unwrap_or("").to_string();
        let seq = self.next_id.fetch_add(1, Ordering::Relaxed);
        let transfer_id = format!("ls-out-{seq}");
        let cancel = Arc::new(AtomicBool::new(false));
        self.outgoing.lock().unwrap().insert(transfer_id.clone(), cancel.clone());

        let ctx = ctx.clone();
        let tid = transfer_id.clone();
        std::thread::spawn(move || {
            run_send(&ctx, &tid, &id, our_port, &peer, &raw_paths, &pin, &cancel);
            ctx.localsend.outgoing.lock().unwrap().remove(&tid);
        });
        Ok(json!({"transfer": transfer_id}))
    }
}

fn collect_outgoing_files(ctx: &Ctx, paths: &[PathBuf]) -> Vec<(String, String, PathBuf, u64, String)> {
    let mut out = Vec::new();
    let mut idx = 0usize;
    fn walk(ctx: &Ctx, root_name: &str, dir: &Path, rel: &str, out: &mut Vec<(String, String, PathBuf, u64, String)>, idx: &mut usize) {
        let Ok(rd) = fs::read_dir(dir) else { return };
        let mut entries: Vec<PathBuf> = rd.flatten().map(|e| e.path()).collect();
        entries.sort();
        for p in entries {
            let Ok(meta) = fs::metadata(&p) else { continue };
            let name = util::name_of(&p);
            let sub = if rel.is_empty() { format!("{root_name}/{name}") } else { format!("{rel}/{name}") };
            if meta.is_dir() {
                walk(ctx, root_name, &p, &sub, out, idx);
            } else if meta.is_file() {
                *idx += 1;
                let mime = ctx.mime.of_file(&p, &name, meta.len());
                out.push((format!("f{idx}"), sub, p, meta.len(), mime));
            }
        }
    }
    for p in paths {
        let Ok(meta) = fs::metadata(p) else { continue };
        let name = util::name_of(p);
        if meta.is_dir() {
            walk(ctx, &name, p, "", &mut out, &mut idx);
        } else if meta.is_file() {
            idx += 1;
            let mime = ctx.mime.of_file(p, &name, meta.len());
            out.push((format!("f{idx}"), name, p.clone(), meta.len(), mime));
        }
    }
    out
}

fn run_send(
    ctx: &Ctx,
    tid: &str,
    id: &Identity,
    our_port: u16,
    peer: &Peer,
    paths: &[PathBuf],
    pin: &str,
    cancel: &AtomicBool,
) {
    let files = collect_outgoing_files(ctx, paths);
    if files.is_empty() {
        ctx.out.event("localsend_transfer", json!({"id": tid, "direction": "send", "peer": peer.alias, "state": "failed", "error": "missing"}));
        return;
    }
    let total_bytes: u64 = files.iter().map(|f| f.3).sum();
    let total_files = files.len() as u64;

    ctx.out.event("localsend_transfer", json!({
        "id": tid, "direction": "send", "peer": peer.alias, "state": "waiting",
        "bytes": 0, "totalBytes": total_bytes, "files": 0, "totalFiles": total_files,
        "current": files[0].1, "rate": 0.0
    }));

    let mut file_map = serde_json::Map::new();
    for (fid, name, _, size, mime) in &files {
        file_map.insert(fid.clone(), json!({
            "id": fid,
            "fileName": name,
            "size": size,
            "fileType": mime,
        }));
    }
    let prep_body = json!({
        "info": info_json(id, our_port, None),
        "files": file_map,
    }).to_string();

    let prep_path = if pin.is_empty() {
        "/api/localsend/v2/prepare-upload".to_string()
    } else {
        format!("/api/localsend/v2/prepare-upload?pin={}", percent_encoding::utf8_percent_encode(pin, percent_encoding::NON_ALPHANUMERIC))
    };

    let resp = match http_request(id, &peer.protocol, &peer.ip, peer.port, "POST", &prep_path, "application/json", prep_body.as_bytes(), Duration::from_secs(90)) {
        Ok(r) => r,
        Err(e) => {
            ctx.out.event("localsend_transfer", json!({"id": tid, "direction": "send", "peer": peer.alias, "state": "failed", "error": e}));
            return;
        }
    };
    if resp.status == 401 {
        ctx.out.event("localsend_transfer", json!({"id": tid, "direction": "send", "peer": peer.alias, "fingerprint": peer.fingerprint, "state": "pin"}));
        return;
    }
    if resp.status == 403 {
        ctx.out.event("localsend_transfer", json!({"id": tid, "direction": "send", "peer": peer.alias, "state": "rejected"}));
        return;
    }
    if resp.status != 200 {
        ctx.out.event("localsend_transfer", json!({"id": tid, "direction": "send", "peer": peer.alias, "state": "failed", "error": format!("http_{}", resp.status)}));
        return;
    }
    let Ok(prep_json) = serde_json::from_slice::<Value>(&resp.body) else {
        ctx.out.event("localsend_transfer", json!({"id": tid, "direction": "send", "peer": peer.alias, "state": "failed", "error": "badjson"}));
        return;
    };
    let session_id = prep_json["sessionId"].as_str().unwrap_or("").to_string();
    let tokens = prep_json["files"].as_object().cloned().unwrap_or_default();
    if session_id.is_empty() || tokens.is_empty() {
        ctx.out.event("localsend_transfer", json!({"id": tid, "direction": "send", "peer": peer.alias, "state": "done", "bytes": total_bytes, "totalBytes": total_bytes, "files": total_files, "totalFiles": total_files}));
        return;
    }

    let mut sent_bytes: u64 = 0;
    let mut done_files: u64 = 0;
    let started = Instant::now();
    let mut last_emit = Instant::now();

    for (fid, name, disk_path, size, _) in &files {
        if cancel.load(Ordering::Relaxed) {
            let _ = http_request(id, &peer.protocol, &peer.ip, peer.port, "POST", &format!("/api/localsend/v2/cancel?sessionId={session_id}"), "application/json", b"", Duration::from_secs(5));
            ctx.out.event("localsend_transfer", json!({"id": tid, "direction": "send", "peer": peer.alias, "state": "cancelled"}));
            return;
        }
        let Some(token) = tokens.get(fid).and_then(|v| v.as_str()) else {
            continue;
        };
        let upload_path = format!(
            "/api/localsend/v2/upload?sessionId={}&fileId={}&token={}",
            percent_encoding::utf8_percent_encode(&session_id, percent_encoding::NON_ALPHANUMERIC),
            percent_encoding::utf8_percent_encode(fid, percent_encoding::NON_ALPHANUMERIC),
            percent_encoding::utf8_percent_encode(token, percent_encoding::NON_ALPHANUMERIC),
        );
        let res = http_upload_file(id, &peer.protocol, &peer.ip, peer.port, &upload_path, disk_path, *size, cancel, |chunk| {
            sent_bytes += chunk as u64;
            if last_emit.elapsed().as_millis() >= 100 {
                last_emit = Instant::now();
                let dt = started.elapsed().as_secs_f64().max(0.05);
                ctx.out.event("localsend_transfer", json!({
                    "id": tid, "direction": "send", "peer": peer.alias, "state": "sending",
                    "bytes": sent_bytes, "totalBytes": total_bytes, "files": done_files, "totalFiles": total_files,
                    "current": name, "rate": sent_bytes as f64 / dt
                }));
            }
        });
        match res {
            Ok(200) => {
                done_files += 1;
            }
            Err(ref e) if e == "cancelled" => {
                let _ = http_request(id, &peer.protocol, &peer.ip, peer.port, "POST", &format!("/api/localsend/v2/cancel?sessionId={session_id}"), "application/json", b"", Duration::from_secs(5));
                ctx.out.event("localsend_transfer", json!({"id": tid, "direction": "send", "peer": peer.alias, "state": "cancelled"}));
                return;
            }
            Ok(code) => {
                ctx.out.event("localsend_transfer", json!({"id": tid, "direction": "send", "peer": peer.alias, "state": "failed", "error": format!("http_{code}")}));
                return;
            }
            Err(e) => {
                ctx.out.event("localsend_transfer", json!({"id": tid, "direction": "send", "peer": peer.alias, "state": "failed", "error": e}));
                return;
            }
        }
    }

    ctx.out.event("localsend_transfer", json!({
        "id": tid, "direction": "send", "peer": peer.alias, "state": "done",
        "bytes": total_bytes, "totalBytes": total_bytes, "files": done_files, "totalFiles": total_files,
        "current": "", "rate": total_bytes as f64 / started.elapsed().as_secs_f64().max(0.05)
    }));
}

fn udp_loop(ctx: &Arc<Ctx>, udp: Arc<UdpSocket>, our_port: u16, id: Arc<Identity>, stop: Arc<AtomicBool>) {
    let mut buf = [0u8; 8192];
    while !stop.load(Ordering::Relaxed) {
        let Ok((n, src)) = udp.recv_from(&mut buf) else { continue };
        let Ok(val) = serde_json::from_slice::<Value>(&buf[..n]) else { continue };
        let fp = val["fingerprint"].as_str().unwrap_or("");
        if fp.is_empty() || fp == id.fingerprint {
            continue;
        }
        let ip = src.ip().to_string();
        let port = val["port"].as_u64().unwrap_or(DEFAULT_PORT as u64) as u16;
        let protocol = val["protocol"].as_str().unwrap_or("https").to_string();
        let peer = Peer {
            fingerprint: fp.to_string(),
            alias: val["alias"].as_str().unwrap_or(&ip).to_string(),
            device_model: val["deviceModel"].as_str().unwrap_or("").to_string(),
            device_type: val["deviceType"].as_str().unwrap_or("desktop").to_string(),
            version: val["version"].as_str().unwrap_or(PROTOCOL_VERSION).to_string(),
            ip: ip.clone(),
            port,
            protocol: protocol.clone(),
            download: val["download"].as_bool().unwrap_or(false),
            last_seen: Instant::now(),
        };
        ctx.localsend.upsert_peer(ctx, peer);

        if val["announce"].as_bool() == Some(true) {
            // Reply to announcing peer via HTTP/HTTPS /register (LocalSend v2.1 spec), with UDP fallback.
            let id_c = id.clone();
            let udp_c = udp.clone();
            std::thread::spawn(move || {
                let body = info_json(&id_c, our_port, None).to_string();
                let res = http_request(&id_c, &protocol, &ip, port, "POST", "/api/localsend/v2/register", "application/json", body.as_bytes(), Duration::from_secs(3));
                if res.is_err() {
                    let reply = info_json(&id_c, our_port, Some(false)).to_string();
                    let _ = udp_c.send_to(reply.as_bytes(), SocketAddrV4::new(MULTICAST_ADDR, DEFAULT_PORT));
                }
            });
        }
    }
}

fn probe_host(ctx: &Ctx, id: &Identity, our_port: u16, host: &str, port: u16) -> bool {
    let body = info_json(id, our_port, None).to_string();
    for proto in ["https", "http"] {
        if let Ok(resp) = http_request(id, proto, host, port, "POST", "/api/localsend/v2/register", "application/json", body.as_bytes(), Duration::from_millis(1200)) {
            if resp.status == 200 {
                if let Ok(val) = serde_json::from_slice::<Value>(&resp.body) {
                    let fp = val["fingerprint"].as_str().unwrap_or("");
                    if !fp.is_empty() && fp != id.fingerprint {
                        let peer = Peer {
                            fingerprint: fp.to_string(),
                            alias: val["alias"].as_str().unwrap_or(host).to_string(),
                            device_model: val["deviceModel"].as_str().unwrap_or("").to_string(),
                            device_type: val["deviceType"].as_str().unwrap_or("desktop").to_string(),
                            version: val["version"].as_str().unwrap_or(PROTOCOL_VERSION).to_string(),
                            ip: host.to_string(),
                            port,
                            protocol: proto.to_string(),
                            download: val["download"].as_bool().unwrap_or(false),
                            last_seen: Instant::now(),
                        };
                        ctx.localsend.upsert_peer(ctx, peer);
                        return true;
                    }
                }
            }
        }
    }
    false
}

fn tcp_loop(ctx: &Arc<Ctx>, listener: TcpListener, port: u16, id: Arc<Identity>, stop: Arc<AtomicBool>) {
    while !stop.load(Ordering::Relaxed) {
        match listener.accept() {
            Ok((stream, addr)) => {
                let ctx = ctx.clone();
                let id = id.clone();
                std::thread::spawn(move || handle_connection(&ctx, stream, addr, port, &id));
            }
            Err(ref e) if e.kind() == std::io::ErrorKind::WouldBlock => {
                std::thread::sleep(Duration::from_millis(50));
            }
            Err(_) => {
                std::thread::sleep(Duration::from_millis(100));
            }
        }
    }
}

trait IoStream: Read + Write {}
impl<T: Read + Write> IoStream for T {}

fn handle_connection(ctx: &Ctx, stream: TcpStream, peer_addr: SocketAddr, our_port: u16, id: &Identity) {
    let _ = stream.set_nonblocking(false);
    let _ = stream.set_read_timeout(Some(Duration::from_secs(30)));
    let _ = stream.set_write_timeout(Some(Duration::from_secs(30)));

    // Auto-detect TLS (0x16 = ClientHello) vs plain HTTP on the same TCP port!
    let mut first = [0u8; 1];
    if stream.peek(&mut first).is_err() {
        return;
    }
    let io: Box<dyn IoStream> = if first[0] == 0x16 {
        let Ok(conn) = ServerConnection::new(id.server_config.clone()) else { return };
        Box::new(StreamOwned::new(conn, stream))
    } else {
        Box::new(stream)
    };
    let mut reader = BufReader::new(io);
    let mut req_line = String::new();
    if reader.read_line(&mut req_line).unwrap_or(0) == 0 {
        return;
    }
    let mut parts = req_line.trim().split_whitespace();
    let method = parts.next().unwrap_or("").to_string();
    let full_path = parts.next().unwrap_or("/").to_string();
    let (path, query_str) = full_path.split_once('?').unwrap_or((&full_path, ""));
    let query = parse_query(query_str);

    let mut content_length: Option<u64> = None;
    let mut chunked = false;
    loop {
        let mut hline = String::new();
        if reader.read_line(&mut hline).unwrap_or(0) == 0 {
            break;
        }
        let trimmed = hline.trim();
        if trimmed.is_empty() {
            break;
        }
        if let Some((k, v)) = trimmed.split_once(':') {
            let kl = k.trim().to_ascii_lowercase();
            let vl = v.trim();
            if kl == "content-length" {
                content_length = vl.parse::<u64>().ok();
            } else if kl == "transfer-encoding" && vl.to_ascii_lowercase().contains("chunked") {
                chunked = true;
            }
        }
    }

    match (method.as_str(), path) {
        ("GET", "/api/localsend/v2/info") => {
            let body = info_json(id, our_port, None).to_string();
            write_http_response(reader.get_mut(), 200, "OK", body.as_bytes());
        }
        ("POST", "/api/localsend/v2/register") => {
            let body = read_body_bounded(&mut reader, content_length, chunked, 64 * 1024).unwrap_or_default();
            if let Ok(val) = serde_json::from_slice::<Value>(&body) {
                let fp = val["fingerprint"].as_str().unwrap_or("");
                if !fp.is_empty() && fp != id.fingerprint {
                    let ip = peer_addr.ip().to_string();
                    let peer = Peer {
                        fingerprint: fp.to_string(),
                        alias: val["alias"].as_str().unwrap_or(&ip).to_string(),
                        device_model: val["deviceModel"].as_str().unwrap_or("").to_string(),
                        device_type: val["deviceType"].as_str().unwrap_or("desktop").to_string(),
                        version: val["version"].as_str().unwrap_or(PROTOCOL_VERSION).to_string(),
                        ip,
                        port: val["port"].as_u64().unwrap_or(DEFAULT_PORT as u64) as u16,
                        protocol: val["protocol"].as_str().unwrap_or("https").to_string(),
                        download: val["download"].as_bool().unwrap_or(false),
                        last_seen: Instant::now(),
                    };
                    ctx.localsend.upsert_peer(ctx, peer);
                }
            }
            let reply = info_json(id, our_port, None).to_string();
            write_http_response(reader.get_mut(), 200, "OK", reply.as_bytes());
        }
        ("POST", "/api/localsend/v2/prepare-upload") => {
            let body = read_body_bounded(&mut reader, content_length, chunked, 4 * 1024 * 1024).unwrap_or_default();
            let Ok(val) = serde_json::from_slice::<Value>(&body) else {
                write_http_response(reader.get_mut(), 400, "Bad Request", b"{}");
                return;
            };
            let sender = &val["info"];
            let sender_alias = sender["alias"].as_str().unwrap_or(&peer_addr.ip().to_string()).to_string();
            let Some(files_obj) = val["files"].as_object() else {
                write_http_response(reader.get_mut(), 400, "Bad Request", b"{}");
                return;
            };
            let seq = ctx.localsend.next_id.fetch_add(1, Ordering::Relaxed);
            let session_id = rand_token("sess", seq);
            let mut inc_files: HashMap<String, IncomingFile> = HashMap::new();
            let mut file_summaries = Vec::new();
            let mut token_map = serde_json::Map::new();
            let mut total_bytes = 0u64;

            for (fid, fv) in files_obj {
                let fname = fv["fileName"].as_str().unwrap_or(fid).to_string();
                let size = fv["size"].as_u64().unwrap_or(0);
                let ftype = fv["fileType"].as_str().unwrap_or("application/octet-stream").to_string();
                if sanitize_rel_path(&fname).is_none() {
                    continue;
                }
                let tok = rand_token(fid, seq);
                total_bytes = total_bytes.saturating_add(size);
                token_map.insert(fid.clone(), json!(tok));
                file_summaries.push(json!({"id": fid, "fileName": fname, "size": size, "fileType": ftype}));
                inc_files.insert(fid.clone(), IncomingFile { file_name: fname, token: tok });
            }
            if inc_files.is_empty() {
                write_http_response(reader.get_mut(), 400, "Bad Request", b"{}");
                return;
            }

            let dest_dir = if ctx.localsend.auto_accept.load(Ordering::Relaxed) {
                Some(ctx.localsend.save_dir.lock().unwrap().clone())
            } else {
                let (tx, rx) = mpsc::channel();
                ctx.localsend.offers.lock().unwrap().insert(session_id.clone(), PendingOffer { tx });
                ctx.out.event("localsend_offer", json!({
                    "sessionId": session_id,
                    "sender": {
                        "alias": sender_alias,
                        "deviceModel": sender["deviceModel"].as_str().unwrap_or(""),
                        "deviceType": sender["deviceType"].as_str().unwrap_or("desktop"),
                        "ip": peer_addr.ip().to_string(),
                    },
                    "files": file_summaries,
                    "totalBytes": total_bytes,
                    "saveDir": ctx.localsend.save_dir.lock().unwrap().to_string_lossy(),
                }));
                let res = rx.recv_timeout(Duration::from_secs(90)).ok().flatten();
                ctx.localsend.offers.lock().unwrap().remove(&session_id);
                res
            };

            let Some(dest_dir) = dest_dir else {
                write_http_response(reader.get_mut(), 403, "Forbidden", b"{\"message\":\"Rejected\"}");
                return;
            };

            let total_files = inc_files.len() as u64;
            let session = Arc::new(Mutex::new(IncomingSession {
                sender_alias: sender_alias.clone(),
                dest_dir,
                files: inc_files,
                total_bytes,
                received_bytes: 0,
                done_files: 0,
                total_files,
                cancelled: Arc::new(AtomicBool::new(false)),
                created: Instant::now(),
            }));
            ctx.localsend.sessions.lock().unwrap().insert(session_id.clone(), session);
            // Prune abandoned incoming sessions older than 1 hour.
            ctx.localsend.sessions.lock().unwrap().retain(|_, s| s.lock().unwrap().created.elapsed().as_secs() < 3600);

            ctx.out.event("localsend_transfer", json!({
                "id": session_id, "direction": "receive", "peer": sender_alias, "state": "receiving",
                "bytes": 0, "totalBytes": total_bytes, "files": 0, "totalFiles": total_files, "current": ""
            }));

            let reply = json!({"sessionId": session_id, "files": token_map}).to_string();
            write_http_response(reader.get_mut(), 200, "OK", reply.as_bytes());
        }
        ("POST", "/api/localsend/v2/upload") => {
            let sid = query.get("sessionId").cloned().unwrap_or_default();
            let fid = query.get("fileId").cloned().unwrap_or_default();
            let tok = query.get("token").cloned().unwrap_or_default();
            let session = ctx.localsend.sessions.lock().unwrap().get(&sid).cloned();
            let Some(session) = session else {
                write_http_response(reader.get_mut(), 403, "Forbidden", b"{}");
                return;
            };
            let (dest_dir, file_name, cancel, sender_alias) = {
                let s = session.lock().unwrap();
                let Some(f) = s.files.get(&fid) else {
                    write_http_response(reader.get_mut(), 403, "Forbidden", b"{}");
                    return;
                };
                if f.token != tok {
                    write_http_response(reader.get_mut(), 403, "Forbidden", b"{}");
                    return;
                }
                (s.dest_dir.clone(), f.file_name.clone(), s.cancelled.clone(), s.sender_alias.clone())
            };
            let Some(rel) = sanitize_rel_path(&file_name) else {
                write_http_response(reader.get_mut(), 400, "Bad Request", b"{}");
                return;
            };
            let target_parent = rel.parent().map(|p| dest_dir.join(p)).unwrap_or_else(|| dest_dir.clone());
            if fs::create_dir_all(&target_parent).is_err() {
                write_http_response(reader.get_mut(), 500, "Internal Server Error", b"{}");
                return;
            }
            let base_name = rel.file_name().map(|n| n.to_string_lossy().into_owned()).unwrap_or_else(|| "file".into());
            let final_path = util::free_name(&target_parent, &base_name);
            let part_path = target_parent.join(format!(".{}.inir-part", util::name_of(&final_path)));
            let Ok(mut out_file) = File::create(&part_path) else {
                write_http_response(reader.get_mut(), 500, "Internal Server Error", b"{}");
                return;
            };

            let mut last_emit = Instant::now();
            let write_res = stream_body_to_file(&mut reader, content_length, chunked, &mut out_file, &cancel, |n| {
                let mut s = session.lock().unwrap();
                s.received_bytes += n as u64;
                if last_emit.elapsed().as_millis() >= 100 {
                    last_emit = Instant::now();
                    ctx.out.event("localsend_transfer", json!({
                        "id": sid, "direction": "receive", "peer": sender_alias, "state": "receiving",
                        "bytes": s.received_bytes, "totalBytes": s.total_bytes,
                        "files": s.done_files, "totalFiles": s.total_files,
                        "current": file_name, "dest": s.dest_dir.to_string_lossy()
                    }));
                }
            });
            drop(out_file);
            if write_res.is_err() || cancel.load(Ordering::Relaxed) {
                let _ = fs::remove_file(&part_path);
                ctx.out.event("localsend_transfer", json!({"id": sid, "direction": "receive", "peer": sender_alias, "state": "cancelled"}));
                write_http_response(reader.get_mut(), 500, "Internal Server Error", b"{}");
                return;
            }
            if fs::rename(&part_path, &final_path).is_err() {
                let _ = fs::remove_file(&part_path);
                write_http_response(reader.get_mut(), 500, "Internal Server Error", b"{}");
                return;
            }
            let (done_all, bytes, total_bytes, done_files, total_files, dest_str) = {
                let mut s = session.lock().unwrap();
                s.done_files += 1;
                (s.done_files >= s.total_files, s.received_bytes, s.total_bytes, s.done_files, s.total_files, s.dest_dir.to_string_lossy().into_owned())
            };
            if done_all {
                ctx.localsend.sessions.lock().unwrap().remove(&sid);
                ctx.out.event("localsend_transfer", json!({
                    "id": sid, "direction": "receive", "peer": sender_alias, "state": "done",
                    "bytes": bytes, "totalBytes": total_bytes, "files": done_files, "totalFiles": total_files,
                    "current": "", "dest": dest_str
                }));
            }
            write_http_response(reader.get_mut(), 200, "OK", b"{}");
        }
        ("POST", "/api/localsend/v2/cancel") => {
            if let Some(sid) = query.get("sessionId") {
                if let Some(offer) = ctx.localsend.offers.lock().unwrap().remove(sid) {
                    let _ = offer.tx.send(None);
                }
                if let Some(sess) = ctx.localsend.sessions.lock().unwrap().remove(sid) {
                    let s = sess.lock().unwrap();
                    s.cancelled.store(true, Ordering::Relaxed);
                    ctx.out.event("localsend_transfer", json!({"id": sid, "direction": "receive", "peer": s.sender_alias, "state": "cancelled"}));
                }
            }
            write_http_response(reader.get_mut(), 200, "OK", b"{}");
        }
        _ => {
            write_http_response(reader.get_mut(), 404, "Not Found", b"{}");
        }
    }
}

fn write_http_response(w: &mut dyn Write, status: u16, reason: &str, body: &[u8]) {
    let head = format!(
        "HTTP/1.1 {status} {reason}\r\nContent-Type: application/json\r\nContent-Length: {}\r\nConnection: close\r\n\r\n",
        body.len()
    );
    let _ = w.write_all(head.as_bytes());
    let _ = w.write_all(body);
    let _ = w.flush();
}

fn read_body_bounded(reader: &mut BufReader<Box<dyn IoStream>>, content_length: Option<u64>, chunked: bool, cap: usize) -> Result<Vec<u8>, String> {
    let mut out = Vec::new();
    if chunked {
        loop {
            let mut line = String::new();
            if reader.read_line(&mut line).map_err(|e| e.to_string())? == 0 {
                break;
            }
            let sz = usize::from_str_radix(line.trim().split(';').next().unwrap_or("0"), 16).unwrap_or(0);
            if sz == 0 {
                break;
            }
            if out.len() + sz > cap {
                return Err("too_large".into());
            }
            let start = out.len();
            out.resize(start + sz, 0);
            reader.read_exact(&mut out[start..]).map_err(|e| e.to_string())?;
            let mut crlf = [0u8; 2];
            let _ = reader.read_exact(&mut crlf);
        }
    } else if let Some(len) = content_length {
        let len = (len as usize).min(cap);
        out.resize(len, 0);
        reader.read_exact(&mut out).map_err(|e| e.to_string())?;
    }
    Ok(out)
}

fn stream_body_to_file(
    reader: &mut BufReader<Box<dyn IoStream>>,
    content_length: Option<u64>,
    chunked: bool,
    out: &mut File,
    cancel: &AtomicBool,
    mut on_bytes: impl FnMut(usize),
) -> Result<(), String> {
    let mut buf = [0u8; 64 * 1024];
    if chunked {
        loop {
            if cancel.load(Ordering::Relaxed) {
                return Err("cancelled".into());
            }
            let mut line = String::new();
            if reader.read_line(&mut line).map_err(|e| e.to_string())? == 0 {
                break;
            }
            let mut rem = usize::from_str_radix(line.trim().split(';').next().unwrap_or("0"), 16).unwrap_or(0);
            if rem == 0 {
                break;
            }
            while rem > 0 {
                if cancel.load(Ordering::Relaxed) {
                    return Err("cancelled".into());
                }
                let take = rem.min(buf.len());
                let n = reader.read(&mut buf[..take]).map_err(|e| e.to_string())?;
                if n == 0 {
                    return Err("eof".into());
                }
                out.write_all(&buf[..n]).map_err(|e| e.to_string())?;
                rem -= n;
                on_bytes(n);
            }
            let mut crlf = [0u8; 2];
            let _ = reader.read_exact(&mut crlf);
        }
    } else if let Some(mut rem) = content_length {
        while rem > 0 {
            if cancel.load(Ordering::Relaxed) {
                return Err("cancelled".into());
            }
            let take = (rem as usize).min(buf.len());
            let n = reader.read(&mut buf[..take]).map_err(|e| e.to_string())?;
            if n == 0 {
                return Err("eof".into());
            }
            out.write_all(&buf[..n]).map_err(|e| e.to_string())?;
            rem -= n as u64;
            on_bytes(n);
        }
    } else {
        loop {
            if cancel.load(Ordering::Relaxed) {
                return Err("cancelled".into());
            }
            let n = reader.read(&mut buf).map_err(|e| e.to_string())?;
            if n == 0 {
                break;
            }
            out.write_all(&buf[..n]).map_err(|e| e.to_string())?;
            on_bytes(n);
        }
    }
    out.flush().map_err(|e| e.to_string())
}

struct HttpResp {
    status: u16,
    body: Vec<u8>,
}

fn connect_client(id: &Identity, protocol: &str, host: &str, port: u16, timeout: Duration) -> Result<Box<dyn IoStream>, String> {
    let ip: IpAddr = host.parse().map_err(|_| "badaddress".to_string())?;
    let tcp = TcpStream::connect_timeout(&SocketAddr::new(ip, port), timeout.min(Duration::from_secs(5)))
        .map_err(|e| e.to_string())?;
    let _ = tcp.set_read_timeout(Some(timeout));
    let _ = tcp.set_write_timeout(Some(timeout));
    if protocol == "https" {
        let sni = ServerName::try_from(ip).map_err(|_| "tls_sni".to_string())?;
        let conn = ClientConnection::new(id.client_config.clone(), sni).map_err(|e| e.to_string())?;
        Ok(Box::new(StreamOwned::new(conn, tcp)))
    } else {
        Ok(Box::new(tcp))
    }
}

fn read_http_response(io: Box<dyn IoStream>) -> Result<HttpResp, String> {
    let mut reader = BufReader::new(io);
    let mut status_line = String::new();
    if reader.read_line(&mut status_line).map_err(|e| e.to_string())? == 0 {
        return Err("eof".into());
    }
    let status = status_line.split_whitespace().nth(1).and_then(|s| s.parse::<u16>().ok()).unwrap_or(0);
    let mut content_length: Option<u64> = None;
    let mut chunked = false;
    loop {
        let mut hline = String::new();
        if reader.read_line(&mut hline).map_err(|e| e.to_string())? == 0 {
            break;
        }
        let t = hline.trim();
        if t.is_empty() {
            break;
        }
        if let Some((k, v)) = t.split_once(':') {
            let kl = k.trim().to_ascii_lowercase();
            let vl = v.trim();
            if kl == "content-length" {
                content_length = vl.parse::<u64>().ok();
            } else if kl == "transfer-encoding" && vl.to_ascii_lowercase().contains("chunked") {
                chunked = true;
            }
        }
    }
    let body = if content_length.is_some() || chunked {
        read_body_bounded(&mut reader, content_length, chunked, 4 * 1024 * 1024)?
    } else {
        let mut b = Vec::new();
        let _ = reader.take(1024 * 1024).read_to_end(&mut b);
        b
    };
    Ok(HttpResp { status, body })
}

fn http_request(
    id: &Identity,
    protocol: &str,
    host: &str,
    port: u16,
    method: &str,
    path: &str,
    content_type: &str,
    body: &[u8],
    timeout: Duration,
) -> Result<HttpResp, String> {
    let mut io = connect_client(id, protocol, host, port, timeout)?;
    let head = format!(
        "{method} {path} HTTP/1.1\r\nHost: {host}:{port}\r\nContent-Type: {content_type}\r\nContent-Length: {}\r\nConnection: close\r\n\r\n",
        body.len()
    );
    io.write_all(head.as_bytes()).map_err(|e| e.to_string())?;
    if !body.is_empty() {
        io.write_all(body).map_err(|e| e.to_string())?;
    }
    io.flush().map_err(|e| e.to_string())?;
    read_http_response(io)
}

fn http_upload_file(
    id: &Identity,
    protocol: &str,
    host: &str,
    port: u16,
    path: &str,
    disk_path: &Path,
    size: u64,
    cancel: &AtomicBool,
    mut on_bytes: impl FnMut(usize),
) -> Result<u16, String> {
    let mut file = File::open(disk_path).map_err(|e| e.to_string())?;
    let mut io = connect_client(id, protocol, host, port, Duration::from_secs(60))?;
    let head = format!(
        "POST {path} HTTP/1.1\r\nHost: {host}:{port}\r\nContent-Type: application/octet-stream\r\nContent-Length: {size}\r\nConnection: close\r\n\r\n"
    );
    io.write_all(head.as_bytes()).map_err(|e| e.to_string())?;
    let mut buf = [0u8; 64 * 1024];
    let mut rem = size;
    while rem > 0 {
        if cancel.load(Ordering::Relaxed) {
            return Err("cancelled".into());
        }
        let take = (rem as usize).min(buf.len());
        let n = file.read(&mut buf[..take]).map_err(|e| e.to_string())?;
        if n == 0 {
            break;
        }
        io.write_all(&buf[..n]).map_err(|e| e.to_string())?;
        rem -= n as u64;
        on_bytes(n);
    }
    io.flush().map_err(|e| e.to_string())?;
    let resp = read_http_response(io)?;
    Ok(resp.status)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn sanitizes_relative_paths_against_traversal() {
        assert_eq!(sanitize_rel_path("photo.jpg"), Some(PathBuf::from("photo.jpg")));
        assert_eq!(sanitize_rel_path("Album/2026/img.png"), Some(PathBuf::from("Album/2026/img.png")));
        assert_eq!(sanitize_rel_path("../etc/passwd"), None);
        assert_eq!(sanitize_rel_path("a/../../b"), None);
        assert_eq!(sanitize_rel_path("/abs/path"), None);
        assert_eq!(sanitize_rel_path(""), None);
    }

    #[test]
    fn generates_valid_self_signed_tls_identity() {
        let id = build_identity("TestPC".into()).unwrap();
        assert_eq!(id.alias, "TestPC");
        assert_eq!(id.fingerprint.len(), 64);
        assert!(id.fingerprint.chars().all(|c| c.is_ascii_hexdigit()));
    }

    #[test]
    fn loopback_https_v2_transfer_roundtrip() {
        let dir = std::env::temp_dir().join(format!("inir-localsend-test-{}", std::process::id()));
        let _ = fs::remove_dir_all(&dir);
        let src_dir = dir.join("src");
        let dst_dir = dir.join("dst");
        fs::create_dir_all(&src_dir).unwrap();
        fs::create_dir_all(&dst_dir).unwrap();
        let src_file = src_dir.join("hello.txt");
        let payload = b"LocalSend v2.1 pure-Rust HTTPS roundtrip payload!";
        fs::write(&src_file, payload).unwrap();

        let ctx = Arc::new(Ctx {
            out: crate::Out,
            mime: crate::mime::MimeDb::load(),
            thumbs: crate::thumbs::Thumbs::new(),
            jobs: crate::jobs::Registry::default(),
            watch: crate::watch::Watch::default(),
            talks: crate::remote::Talks::default(),
            portal: crate::portal::Registry::default(),
            admin: crate::admin::Admin::default(),
            localsend: LocalSend::default(),
            cancels: Mutex::new(HashMap::new()),
        });
        ctx.localsend.auto_accept.store(true, Ordering::Relaxed);
        *ctx.localsend.save_dir.lock().unwrap() = dst_dir.clone();

        let server_id = Arc::new(build_identity("Receiver".into()).unwrap());
        let client_id = Arc::new(build_identity("Sender".into()).unwrap());
        let listener = TcpListener::bind("127.0.0.1:0").unwrap();
        let port = listener.local_addr().unwrap().port();
        let _ = listener.set_nonblocking(true);
        let stop = Arc::new(AtomicBool::new(false));
        let stop_bg = stop.clone();
        let ctx_bg = ctx.clone();
        let sid_bg = server_id.clone();
        let handle = std::thread::spawn(move || tcp_loop(&ctx_bg, listener, port, sid_bg, stop_bg));

        // 1. GET /info over HTTPS
        let info = http_request(&client_id, "https", "127.0.0.1", port, "GET", "/api/localsend/v2/info", "application/json", b"", Duration::from_secs(5)).unwrap();
        assert_eq!(info.status, 200);
        let iv: Value = serde_json::from_slice(&info.body).unwrap();
        assert_eq!(iv["alias"], "Receiver");
        assert_eq!(iv["version"], "2.1");

        // 2. Full prepare-upload + upload over HTTPS
        let peer = Peer {
            fingerprint: server_id.fingerprint.clone(),
            alias: "Receiver".into(),
            device_model: "Linux".into(),
            device_type: "desktop".into(),
            version: "2.1".into(),
            ip: "127.0.0.1".into(),
            port,
            protocol: "https".into(),
            download: false,
            last_seen: Instant::now(),
        };
        let cancel = AtomicBool::new(false);
        run_send(&ctx, "t1", &client_id, port, &peer, &[src_file], "", &cancel);

        let received = fs::read(dst_dir.join("hello.txt")).unwrap();
        assert_eq!(received, payload);

        stop.store(true, Ordering::Relaxed);
        let _ = handle.join();
        let _ = fs::remove_dir_all(&dir);
    }
}
