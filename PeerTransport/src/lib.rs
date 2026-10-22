//! A bounded, authenticated byte tunnel. Media framing and BLE input stay in the host apps.
use anyhow::{Context, Result};
use hmac::{Hmac, Mac};
use iroh::{
    Endpoint, EndpointAddr, EndpointId, SecretKey,
    endpoint::{Connection, QuicTransportConfig, RecvStream, RelayMode, SendStream, presets},
};
use iroh_mdns_address_lookup::MdnsAddressLookup;
use sha2::Sha256;
use std::{
    net::{IpAddr, Ipv4Addr, Ipv6Addr, SocketAddr, TcpListener},
    sync::{
        Arc, RwLock,
        atomic::{AtomicU64, Ordering},
    },
    thread,
    time::Duration,
};
use tokio::{
    io::{AsyncRead, AsyncWrite, AsyncWriteExt, ReadBuf},
    sync::{oneshot, watch},
};
use zeroize::Zeroize;

const ALPN: &[u8] = b"droidmirror/video/1";
const AUDIO_ALPN: &[u8] = b"droidmirror/audio/1";

fn diagnostic(message: &str) {
    #[cfg(target_os = "android")]
    {
        use std::ffi::CString;
        #[link(name = "log")]
        unsafe extern "C" {
            fn __android_log_write(
                priority: i32,
                tag: *const std::ffi::c_char,
                text: *const std::ffi::c_char,
            ) -> i32;
        }
        if let Ok(text) = CString::new(message) {
            unsafe {
                __android_log_write(4, c"DroidMirrorIroh".as_ptr(), text.as_ptr());
            }
        }
    }
    #[cfg(not(target_os = "android"))]
    eprintln!("Iroh: {message}");
}

fn identity(key: &[u8; 32], role: &[u8]) -> SecretKey {
    let mut mac = Hmac::<Sha256>::new_from_slice(key).expect("HMAC key length");
    mac.update(b"DroidMirror Iroh identity v1/");
    mac.update(role);
    let mut seed: [u8; 32] = mac.finalize().into_bytes().into();
    let secret = SecretKey::from_bytes(&seed);
    seed.zeroize();
    secret
}

async fn endpoint(secret: SecretKey) -> Result<Endpoint> {
    // LAN discovery only: never register with public discovery or relay services.
    let ep = Endpoint::builder(presets::Minimal)
        .relay_mode(RelayMode::Disabled)
        // Conservative datagrams work across Android VPN interfaces as well as
        // LAN. Do not rely on offload or path-MTU support in a tunnel driver.
        .transport_config(
            QuicTransportConfig::builder()
                .initial_mtu(1200)
                .mtu_discovery_config(None)
                .enable_segmentation_offload(false)
                .build(),
        )
        .secret_key(secret)
        .alpns(vec![ALPN.to_vec(), AUDIO_ALPN.to_vec()])
        .bind()
        .await?;
    // A network blocking multicast leaves this path unavailable; the host tries ADB.
    if let Ok(mdns) = MdnsAddressLookup::builder().build(ep.id()) {
        ep.address_lookup()
            .context("address lookup disabled")?
            .add(mdns);
    }
    diagnostic("LAN endpoint bound; relays and public discovery disabled");
    Ok(ep)
}

async fn tunnel<S>(socket: S, conn: &Connection, outgoing: bool) -> Result<()>
where
    S: AsyncRead + AsyncWrite + Unpin,
{
    let (send, recv) = prepare_stream(conn, outgoing).await?;
    copy_stream(socket, send, recv).await
}

async fn prepare_stream(conn: &Connection, outgoing: bool) -> Result<(SendStream, RecvStream)> {
    let (mut send, mut recv) = if outgoing {
        conn.open_bi().await?
    } else {
        tokio::time::timeout(Duration::from_secs(5), conn.accept_bi()).await??
    };
    // QUIC does not announce an opened stream until its first write. Android's
    // application handshake speaks first, so send/consume an internal preface.
    if outgoing {
        send.write_all(b"DMPEER01").await?;
    } else {
        let mut preface = [0; 8];
        tokio::time::timeout(Duration::from_secs(5), recv.read_exact(&mut preface)).await??;
        anyhow::ensure!(&preface == b"DMPEER01", "invalid tunnel preface");
    }
    Ok((send, recv))
}

async fn copy_stream<S>(socket: S, mut send: SendStream, mut recv: RecvStream) -> Result<()>
where
    S: AsyncRead + AsyncWrite + Unpin,
{
    let (mut input, mut output) = tokio::io::split(socket);
    let local_bytes = Arc::new(AtomicU64::new(0));
    let remote_bytes = Arc::new(AtomicU64::new(0));
    let mut input = MeteredRead(&mut input, local_bytes.clone());
    let mut recv = MeteredRead(&mut recv, remote_bytes.clone());
    // End both directions on EOF/error; do not leave a video writer blocked after teardown.
    tokio::select! {
        result = async { tokio::io::copy(&mut input, &mut send).await?; send.finish()?; Ok::<_, anyhow::Error>(()) } => result?,
        result = async { tokio::io::copy(&mut recv, &mut output).await?; output.shutdown().await?; Ok::<_, anyhow::Error>(()) } => result?,
        _ = async {
            for _ in 0..3 {
                tokio::time::sleep(Duration::from_secs(2)).await;
                diagnostic(&format!("Tunnel bytes read: local={} peer={}", local_bytes.load(Ordering::Relaxed), remote_bytes.load(Ordering::Relaxed)));
            }
            std::future::pending::<()>().await;
        } => unreachable!(),
    }
    Ok(())
}

struct MeteredRead<R>(R, Arc<AtomicU64>);
impl<R: AsyncRead + Unpin> AsyncRead for MeteredRead<R> {
    fn poll_read(
        mut self: std::pin::Pin<&mut Self>,
        cx: &mut std::task::Context<'_>,
        buf: &mut ReadBuf<'_>,
    ) -> std::task::Poll<std::io::Result<()>> {
        let before = buf.filled().len();
        let result = std::pin::Pin::new(&mut self.0).poll_read(cx, buf);
        self.1
            .fetch_add((buf.filled().len() - before) as u64, Ordering::Relaxed);
        result
    }
}

#[cfg(any(test, target_os = "android"))]
fn paired(conn: &Connection, expected: EndpointId) -> bool {
    if conn.remote_id() == expected {
        return true;
    }
    conn.close(1u32.into(), b"unpaired peer");
    false
}

// BLE hints commonly arrive after the first multicast dial has started. Keep
// the same local consumer and deadline, but immediately redial with new hints.
// A failed discovery attempt must also stay alive for those authenticated hints.
async fn connect_direct(
    ep: &Endpoint,
    peer: EndpointId,
    hints: &RwLock<Vec<SocketAddr>>,
    mut changed: watch::Receiver<u64>,
    alpn: &'static [u8],
) -> Result<Connection> {
    let deadline = tokio::time::Instant::now() + Duration::from_secs(5);
    loop {
        changed.borrow_and_update();
        let mut address = EndpointAddr::new(peer);
        for hint in hints.read().expect("address hints poisoned").iter() {
            address = address.with_ip_addr(*hint);
        }
        tokio::select! {
            result = tokio::time::timeout_at(deadline, ep.connect(address, alpn)) => {
                match result {
                    Ok(Ok(conn)) => return Ok(conn),
                    Ok(Err(error)) => {
                        tokio::time::timeout_at(deadline, changed.changed()).await
                            .context("direct IP discovery timed out")?
                            .context("address publisher stopped")?;
                        diagnostic(&format!("Retrying direct IP with updated BLE hints after {error}"));
                    }
                    Err(error) => return Err(error.into()),
                }
            }
            result = changed.changed() => {
                result.context("address publisher stopped")?;
            }
        }
    }
}

async fn desktop(
    ep: Endpoint,
    peer: EndpointId,
    listener: TcpListener,
    hints: Arc<RwLock<Vec<SocketAddr>>>,
    hint_updates: watch::Receiver<u64>,
    alpn: &'static [u8],
) -> Result<()> {
    listener.set_nonblocking(true)?;
    let listener = tokio::net::TcpListener::from_std(listener)?;
    let mut failures = 0;
    loop {
        let (socket, _) = listener.accept().await?;
        socket.set_nodelay(true)?;
        // One local consumer and one QUIC stream at a time; no unbounded task spawning.
        match connect_direct(&ep, peer, &hints, hint_updates.clone(), alpn).await {
            Ok(conn) => {
                if let Some(path) = conn.paths().iter().find(|path| path.is_selected()) {
                    diagnostic(&format!(
                        "Paired QUIC connection established over direct IP: {:?}",
                        path.remote_addr()
                    ));
                }
                if let Err(error) = tunnel(socket, &conn, true).await {
                    if failures < 3 {
                        diagnostic(&format!("Video tunnel failed: {error:#}"));
                    }
                    failures += 1;
                }
                conn.close(0u32.into(), b"video disconnected");
            }
            error => {
                if failures < 3 {
                    diagnostic(&format!("Peer connection failed: {error:?}"));
                }
                failures += 1;
            }
        }
    }
}

#[cfg(target_os = "android")]
async fn phone(ep: Endpoint, peer: EndpointId) -> Result<()> {
    use std::os::{
        android::net::SocketAddrExt,
        unix::net::{SocketAddr, UnixStream},
    };
    let permits = Arc::new(tokio::sync::Semaphore::new(2));
    while let Some(incoming) = ep.accept().await {
        let Ok(Ok(conn)) = tokio::time::timeout(Duration::from_secs(5), incoming).await else {
            continue;
        };
        if !paired(&conn, peer) {
            continue;
        }
        let Ok(permit) = permits.clone().try_acquire_owned() else {
            conn.close(1u32.into(), b"media connection limit");
            continue;
        };
        let audio = conn.alpn() == AUDIO_ALPN;
        tokio::spawn(async move {
            let _permit = permit;
            let name = if audio {
                b"droidmirror_audio_upgrade".as_slice()
            } else {
                b"droidmirror_video_upgrade".as_slice()
            };
            let address = match SocketAddr::from_abstract_name(name) {
                Ok(a) => a,
                Err(_) => return,
            };
            // The two independent QUIC connections never share application queues.
            // Pair identity, ALPN and the application's fresh proof gate both.
            let streams = match prepare_stream(&conn, false).await {
                Ok(streams) => streams,
                Err(_) => {
                    conn.close(0u32.into(), b"stream setup failed");
                    return;
                }
            };
            let socket = tokio::time::timeout(Duration::from_secs(15), async {
                loop {
                    match UnixStream::connect_addr(&address) {
                        Ok(socket) => break Ok::<_, std::io::Error>(socket),
                        Err(_) => tokio::time::sleep(Duration::from_millis(50)).await,
                    }
                }
            })
            .await;
            if let Ok(Ok(socket)) = socket {
                if socket.set_nonblocking(true).is_ok() {
                    if let Ok(socket) = tokio::net::UnixStream::from_std(socket) {
                        if let Err(error) = copy_stream(socket, streams.0, streams.1).await {
                            diagnostic(&format!("Media tunnel failed: {error:#}"));
                        }
                    }
                }
            }
            conn.close(0u32.into(), b"media disconnected");
        });
    }
    Ok(())
}

pub struct Bridge {
    audio_port: u16,
    local: Arc<RwLock<Option<Endpoint>>>,
    remote: Arc<RwLock<Vec<SocketAddr>>>,
    hint_updates: watch::Sender<u64>,
    stop: Option<oneshot::Sender<()>>,
    worker: Option<thread::JoinHandle<()>>,
}
impl Drop for Bridge {
    fn drop(&mut self) {
        if let Some(stop) = self.stop.take() {
            let _ = stop.send(());
        }
        if let Some(worker) = self.worker.take() {
            let _ = worker.join();
        }
        self.local.write().expect("local endpoint poisoned").take();
    }
}

fn start(mut key: [u8; 32], is_phone: bool) -> Result<(Bridge, u16)> {
    let secret = identity(&key, if is_phone { b"phone" } else { b"mac" });
    let peer = identity(&key, if is_phone { b"mac" } else { b"phone" }).public();
    key.zeroize();
    let listener = if is_phone {
        None
    } else {
        Some(TcpListener::bind(("127.0.0.1", 0))?)
    };
    let port = listener
        .as_ref()
        .map(|l| l.local_addr().map(|a| a.port()))
        .transpose()?
        .unwrap_or(0);
    let audio_listener = if is_phone {
        None
    } else {
        Some(TcpListener::bind(("127.0.0.1", 0))?)
    };
    let audio_port = audio_listener
        .as_ref()
        .map(|l| l.local_addr().map(|a| a.port()))
        .transpose()?
        .unwrap_or(0);
    let runtime = tokio::runtime::Builder::new_multi_thread()
        .worker_threads(2)
        .enable_all()
        .build()?;
    let local = Arc::new(RwLock::new(None));
    let remote = Arc::new(RwLock::new(Vec::new()));
    let (hint_updates, updates) = watch::channel(0);
    let worker_local = local.clone();
    let worker_remote = remote.clone();
    let (stop, stopped) = oneshot::channel();
    let worker = thread::Builder::new().name("DroidMirrorIroh".into()).spawn(move || {
        let cleanup_local = worker_local.clone();
        runtime.block_on(async move {
            // Cancellation also covers bind/discovery, so teardown never waits for a network timeout.
            tokio::select! {
                _ = stopped => {},
                result = async {
                    let ep = endpoint(secret).await?;
                    *worker_local.write().expect("local endpoint poisoned") = Some(ep.clone());
                    if let Some(listener) = listener {
                        let audio_listener = audio_listener.context("audio listener missing")?;
                        tokio::try_join!(
                            desktop(ep.clone(), peer, listener, worker_remote.clone(), updates.clone(), ALPN),
                            desktop(ep, peer, audio_listener, worker_remote, updates, AUDIO_ALPN)
                        )?;
                        Ok(())
                    }
                    else {
                        #[cfg(target_os = "android")]
                        { phone(ep, peer).await }
                        #[cfg(not(target_os = "android"))]
                        { anyhow::bail!("phone endpoint requires Android") }
                    }
                } => { if let Err(error) = result { diagnostic(&format!("Video transport stopped: {error:#}")); } }
            }
        });
        cleanup_local.write().expect("local endpoint poisoned").take();
        runtime.shutdown_timeout(Duration::from_secs(1));
    })?;
    Ok((
        Bridge {
            audio_port,
            local,
            remote,
            hint_updates,
            stop: Some(stop),
            worker: Some(worker),
        },
        port,
    ))
}

/// Starts a Mac tunnel. Key is copied immediately and never persisted or logged.
/// # Safety
/// key must point to 32 readable bytes; port must point to a writable u16.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn dm_peer_start(key: *const u8, port: *mut u16) -> *mut Bridge {
    if key.is_null() || port.is_null() {
        return std::ptr::null_mut();
    }
    let mut bytes = [0; 32];
    unsafe {
        bytes.copy_from_slice(std::slice::from_raw_parts(key, 32));
    }
    let result = start(bytes, false);
    bytes.zeroize();
    match result {
        Ok((bridge, value)) => {
            unsafe {
                *port = value;
            }
            Box::into_raw(Box::new(bridge))
        }
        Err(_) => std::ptr::null_mut(),
    }
}

/// Audio has its own bounded local listener and encrypted peer connection.
/// # Safety
/// bridge must be a live handle returned by dm_peer_start.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn dm_peer_audio_port(bridge: *const Bridge) -> u16 {
    unsafe { bridge.as_ref() }
        .map(|b| b.audio_port)
        .unwrap_or(0)
}

/// Accept only concrete unicast IP candidates; TLS still authenticates the paired identity.
fn add_hint(bridge: &Bridge, family: u8, bytes: &[u8], port: u16) -> bool {
    let mut hints = bridge.remote.write().expect("address hints poisoned");
    if family == 0 {
        if !hints.is_empty() {
            hints.clear();
            bridge
                .hint_updates
                .send_modify(|version| *version = version.wrapping_add(1));
        }
        return true;
    }
    if port == 0 {
        return false;
    }
    let ip = match family {
        4 if bytes.len() >= 4 => IpAddr::V4(Ipv4Addr::new(bytes[0], bytes[1], bytes[2], bytes[3])),
        16 if bytes.len() >= 16 => {
            IpAddr::V6(Ipv6Addr::from(<[u8; 16]>::try_from(&bytes[..16]).unwrap()))
        }
        _ => return false,
    };
    if ip.is_loopback()
        || ip.is_unspecified()
        || ip.is_multicast()
        || matches!(ip, IpAddr::V6(v6) if v6.is_unicast_link_local())
    {
        return false;
    }
    let address = SocketAddr::new(ip, port);
    if !hints.contains(&address) && hints.len() < 32 {
        hints.push(address);
        bridge
            .hint_updates
            .send_modify(|version| *version = version.wrapping_add(1));
    }
    true
}

/// # Safety
/// handle must be live; bytes must point to at least 16 readable bytes unless family is zero.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn dm_peer_add_address(
    handle: *mut Bridge,
    family: u8,
    bytes: *const u8,
    port: u16,
) -> bool {
    if handle.is_null() || (family != 0 && bytes.is_null()) {
        return false;
    }
    let raw = if family == 0 {
        &[][..]
    } else {
        unsafe { std::slice::from_raw_parts(bytes, 16) }
    };
    add_hint(unsafe { &*handle }, family, raw, port)
}

/// # Safety
/// handle must be a live pointer returned by dm_peer_start, passed exactly once.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn dm_peer_stop(handle: *mut Bridge) {
    if !handle.is_null() {
        unsafe {
            drop(Box::from_raw(handle));
        }
    }
}

#[cfg(target_os = "android")]
mod android {
    use super::*;
    use jni::{
        JNIEnv,
        objects::{GlobalRef, JByteArray, JClass, JObject},
        sys::{jlong, jstring},
    };
    // The JVM application reference lives for the process lifetime, as required
    // by Android network-interface enumeration in Iroh's netdev dependency.
    static APPLICATION: std::sync::OnceLock<GlobalRef> = std::sync::OnceLock::new();
    static INITIALIZE: std::sync::Mutex<()> = std::sync::Mutex::new(());
    #[unsafe(no_mangle)]
    pub extern "system" fn Java_app_droidmirror_bluetooth_PeerVideoTransport_nativeStart(
        mut env: JNIEnv,
        _: JClass,
        context: JObject,
        key: JByteArray,
    ) -> jlong {
        let Ok(_guard) = INITIALIZE.lock() else {
            return 0;
        };
        if APPLICATION.get().is_none() {
            let Ok(application) = env.new_global_ref(context) else {
                return 0;
            };
            let Ok(vm) = env.get_java_vm() else {
                return 0;
            };
            unsafe {
                ndk_context::initialize_android_context(
                    vm.get_java_vm_pointer().cast(),
                    application.as_obj().as_raw().cast(),
                );
            }
            let _ = APPLICATION.set(application);
        }
        let Ok(mut bytes) = env.convert_byte_array(key) else {
            return 0;
        };
        if bytes.len() != 32 {
            bytes.zeroize();
            return 0;
        }
        let mut fixed = [0; 32];
        fixed.copy_from_slice(&bytes);
        bytes.zeroize();
        let result = start(fixed, true);
        fixed.zeroize();
        match result {
            Ok((bridge, _)) => Box::into_raw(Box::new(bridge)) as jlong,
            Err(_) => {
                let _ = env.throw_new("java/io/IOException", "Cannot start Iroh video transport");
                0
            }
        }
    }
    #[unsafe(no_mangle)]
    pub extern "system" fn Java_app_droidmirror_bluetooth_PeerVideoTransport_nativeAddresses(
        env: JNIEnv,
        _: JClass,
        handle: jlong,
    ) -> jstring {
        if handle == 0 {
            return std::ptr::null_mut();
        }
        let bridge = unsafe { &*(handle as *const Bridge) };
        let endpoints = bridge.local.read().expect("local endpoint poisoned");
        let text = endpoints
            .as_ref()
            .map(|ep| {
                let mut addresses = ep.bound_sockets();
                addresses.extend(ep.addr().ip_addrs().copied());
                addresses
                    .iter()
                    .take(32)
                    .map(ToString::to_string)
                    .collect::<Vec<_>>()
                    .join("\n")
            })
            .unwrap_or_default();
        env.new_string(text)
            .map(|s| s.into_raw())
            .unwrap_or(std::ptr::null_mut())
    }
    #[unsafe(no_mangle)]
    pub extern "system" fn Java_app_droidmirror_bluetooth_PeerVideoTransport_nativeStop(
        _: JNIEnv,
        _: JClass,
        handle: jlong,
    ) {
        unsafe {
            dm_peer_stop(handle as *mut Bridge);
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn credentials_are_stable_separated_and_pair_specific() {
        let key = [42; 32];
        assert_eq!(
            identity(&key, b"phone").public(),
            identity(&key, b"phone").public()
        );
        assert_ne!(
            identity(&key, b"phone").public(),
            identity(&key, b"mac").public()
        );
        assert_ne!(
            identity(&key, b"phone").public(),
            identity(&[43; 32], b"phone").public()
        );
    }
    #[test]
    fn teardown_without_network_is_bounded() {
        let started = std::time::Instant::now();
        let (bridge, port) = start([42; 32], false).unwrap();
        assert_ne!(port, 0);
        drop(bridge);
        assert!(started.elapsed() < Duration::from_secs(3));
        assert!(std::net::TcpStream::connect(("127.0.0.1", port)).is_err());
    }

    #[tokio::test]
    async fn audio_lane_progresses_while_video_is_blocked() {
        use tokio::io::AsyncReadExt;
        tokio::time::timeout(Duration::from_secs(10), async {
            let key = [81; 32];
            let server = Endpoint::builder(presets::Minimal)
                .secret_key(identity(&key, b"phone"))
                .alpns(vec![ALPN.to_vec(), AUDIO_ALPN.to_vec()])
                .bind()
                .await
                .unwrap();
            let (bridge, port) = start(key, false).unwrap();
            bridge
                .remote
                .write()
                .unwrap()
                .extend(server.addr().ip_addrs().copied());
            let _video = tokio::net::TcpStream::connect(("127.0.0.1", port))
                .await
                .unwrap();
            let video_conn = server.accept().await.unwrap().await.unwrap();
            assert_eq!(video_conn.alpn(), ALPN);
            let _blocked_video = prepare_stream(&video_conn, false).await.unwrap();
            let mut audio = tokio::net::TcpStream::connect(("127.0.0.1", bridge.audio_port))
                .await
                .unwrap();
            let audio_conn = server.accept().await.unwrap().await.unwrap();
            assert_eq!(audio_conn.alpn(), AUDIO_ALPN);
            assert!(paired(&audio_conn, identity(&key, b"mac").public()));
            let (mut send, _recv) = prepare_stream(&audio_conn, false).await.unwrap();
            send.write_all(b"audio progresses").await.unwrap();
            let mut result = [0; 16];
            audio.read_exact(&mut result).await.unwrap();
            assert_eq!(&result, b"audio progresses");
            drop(bridge);
            server.close().await;
        })
        .await
        .unwrap();
    }

    #[tokio::test]
    async fn explicit_hints_connect_without_multicast_or_public_discovery() {
        use tokio::io::AsyncReadExt;
        tokio::time::timeout(Duration::from_secs(10), async {
            let key = [71; 32];
            let server = Endpoint::builder(presets::Minimal)
                .secret_key(identity(&key, b"phone"))
                .alpns(vec![ALPN.to_vec()])
                .bind()
                .await
                .unwrap();
            let (bridge, port) = start(key, false).unwrap();
            // Only explicit BLE-equivalent hints locate this server: it has no discovery.
            bridge
                .remote
                .write()
                .unwrap()
                .extend(server.addr().ip_addrs().copied());
            let mut app = tokio::net::TcpStream::connect(("127.0.0.1", port))
                .await
                .unwrap();
            let phone = tokio::spawn(async move {
                let conn = server.accept().await.unwrap().await.unwrap();
                assert!(paired(&conn, identity(&key, b"mac").public()));
                let (mut send, mut recv) = prepare_stream(&conn, false).await.unwrap();
                send.write_all(b"DMWIFI03").await.unwrap();
                let mut ready = [0; 1];
                recv.read_exact(&mut ready).await.unwrap();
                assert_eq!(ready, [1]);
                (server, conn)
            });
            let mut hello = [0; 8];
            app.read_exact(&mut hello).await.unwrap();
            assert_eq!(&hello, b"DMWIFI03");
            app.write_all(&[1]).await.unwrap();
            let (server, conn) = phone.await.unwrap();
            drop(app);
            drop(bridge);
            conn.close(0u32.into(), b"done");
            server.close().await;
        })
        .await
        .unwrap();
    }

    #[tokio::test]
    async fn late_ble_hints_wake_an_in_flight_dial_without_reopening_the_local_stream() {
        tokio::time::timeout(Duration::from_secs(4), async {
            let key = [91; 32];
            // No multicast or public lookup: only the later BLE-equivalent hint
            // can connect these endpoints.
            let server = Endpoint::builder(presets::Minimal)
                .secret_key(identity(&key, b"phone"))
                .alpns(vec![ALPN.to_vec()])
                .bind()
                .await
                .unwrap();
            let client = Endpoint::builder(presets::Minimal)
                .secret_key(identity(&key, b"mac"))
                .bind()
                .await
                .unwrap();
            let hints = Arc::new(RwLock::new(vec!["192.0.2.1:12345".parse().unwrap()]));
            let (updates, receiver) = watch::channel(0);
            let dial_hints = hints.clone();
            let dial_client = client.clone();
            let peer = server.id();
            let dial = tokio::spawn(async move {
                connect_direct(&dial_client, peer, &dial_hints, receiver, ALPN).await
            });
            tokio::time::sleep(Duration::from_millis(200)).await;
            assert!(!dial.is_finished());
            let shared_at = std::time::Instant::now();
            *hints.write().unwrap() = server.addr().ip_addrs().copied().collect();
            updates.send_modify(|version| *version += 1);
            let incoming = server.accept().await.unwrap().await.unwrap();
            let outgoing = dial.await.unwrap().unwrap();
            assert!(
                shared_at.elapsed() < Duration::from_secs(2),
                "late hints must not wait for the old five-second dial"
            );
            assert!(paired(&incoming, identity(&key, b"mac").public()));
            assert_eq!(outgoing.remote_id(), peer);
            outgoing.close(0u32.into(), b"done");
            server.close().await;
            client.close().await;
        })
        .await
        .unwrap();
    }

    #[test]
    fn hint_validation_and_reset() {
        let (bridge, _) = start([72; 32], false).unwrap();
        assert!(add_hint(&bridge, 4, &[100, 108, 251, 24], 12345));
        assert!(add_hint(&bridge, 4, &[100, 108, 251, 24], 12345));
        assert_eq!(bridge.remote.read().unwrap().len(), 1);
        assert!(!add_hint(&bridge, 4, &[127, 0, 0, 1], 12345));
        assert!(!add_hint(&bridge, 4, &[224, 0, 0, 1], 12345));
        assert!(!add_hint(&bridge, 4, &[100, 108, 251, 24], 0));
        assert!(!add_hint(&bridge, 16, &[1; 4], 12345));
        assert!(add_hint(&bridge, 0, &[], 0));
        assert!(bridge.remote.read().unwrap().is_empty());
    }

    #[tokio::test]
    async fn production_endpoint_disables_relays_and_public_discovery() {
        let ep = endpoint(identity(&[42; 32], b"mac")).await.unwrap();
        assert_eq!(ep.addr().relay_urls().count(), 0);
        // The only allowed address lookup is local multicast, if available.
        assert!(ep.address_lookup().unwrap().len() <= 1);
        ep.close().await;
    }

    #[tokio::test]
    async fn application_challenge_starts_only_after_delayed_quic_stream() {
        tokio::time::timeout(Duration::from_secs(8), async {
            let server = Endpoint::builder(presets::Minimal)
                .alpns(vec![ALPN.to_vec()])
                .bind()
                .await
                .unwrap();
            let client = Endpoint::builder(presets::Minimal).bind().await.unwrap();
            let (outgoing, incoming) = tokio::join!(client.connect(server.addr(), ALPN), async {
                server.accept().await.unwrap().await.unwrap()
            });
            let outgoing = outgoing.unwrap();
            let application_opened = std::sync::Arc::new(std::sync::atomic::AtomicBool::new(false));
            let opened = application_opened.clone();
            let phone = tokio::spawn(async move {
                let (mut send, _) = prepare_stream(&incoming, false).await.unwrap();
                // Production Android opens the application's local socket here.
                opened.store(true, std::sync::atomic::Ordering::SeqCst);
                send.write_all(b"DMWIFI03").await.unwrap();
                incoming
            });
            // A cold dial/direct-path search can exceed the application's two-second budget.
            tokio::time::sleep(Duration::from_secs(3)).await;
            assert!(!application_opened.load(std::sync::atomic::Ordering::SeqCst));
            let (_, mut recv) = prepare_stream(&outgoing, true).await.unwrap();
            let mut hello = [0; 8];
            tokio::time::timeout(Duration::from_secs(2), recv.read_exact(&mut hello))
                .await
                .unwrap()
                .unwrap();
            assert_eq!(&hello, b"DMWIFI03");
            assert!(application_opened.load(std::sync::atomic::Ordering::SeqCst));
            let incoming = phone.await.unwrap();
            incoming.close(0u32.into(), b"test completed");
            server.close().await;
            client.close().await;
        })
        .await
        .unwrap();
    }

    #[tokio::test]
    async fn direct_quic_preserves_bidirectional_video_bytes_and_rejects_unpaired_peer() {
        use tokio::io::{AsyncReadExt, AsyncWriteExt};
        tokio::time::timeout(Duration::from_secs(10), async {
            // No relay or public discovery: this exercises encrypted direct transport offline.
            let server = Endpoint::builder(presets::Minimal)
                .alpns(vec![ALPN.to_vec()])
                .bind()
                .await
                .unwrap();
            let client = Endpoint::builder(presets::Minimal).bind().await.unwrap();
            let (outgoing, incoming) = tokio::join!(client.connect(server.addr(), ALPN), async {
                server.accept().await.unwrap().await.unwrap()
            });
            let outgoing = outgoing.unwrap();
            assert!(paired(&incoming, client.id()));
            let (mac_socket, mut mac_app) = tokio::io::duplex(4096);
            let (phone_socket, mut phone_app) = tokio::io::duplex(4096);
            let mac = tokio::spawn(async move { tunnel(mac_socket, &outgoing, true).await });
            let phone = tokio::spawn(async move { tunnel(phone_socket, &incoming, false).await });
            let payload: Vec<u8> = (0..2_000_000).map(|n| (n % 251) as u8).collect();
            let (_, received) = tokio::join!(
                async {
                    // Android sends the nonce before the Mac sends anything on the stream.
                    phone_app.write_all(b"DMWIFI03").await.unwrap();
                    let mut ready = [0; 1];
                    phone_app.read_exact(&mut ready).await.unwrap();
                    assert_eq!(ready, [1]);
                    phone_app.write_all(&payload).await.unwrap();
                },
                async {
                    let mut hello = [0; 8];
                    mac_app.read_exact(&mut hello).await.unwrap();
                    assert_eq!(&hello, b"DMWIFI03");
                    mac_app.write_all(&[1]).await.unwrap();
                    let mut actual = vec![0; payload.len()];
                    mac_app.read_exact(&mut actual).await.unwrap();
                    actual
                }
            );
            assert_eq!(received, payload);
            drop(mac_app);
            drop(phone_app);
            mac.await.unwrap().unwrap();
            phone.await.unwrap().unwrap();
            let (outgoing, incoming) = tokio::join!(client.connect(server.addr(), ALPN), async {
                server.accept().await.unwrap().await.unwrap()
            });
            assert!(!paired(&incoming, identity(&[9; 32], b"mac").public()));
            outgoing.unwrap().closed().await;
            server.close().await;
            client.close().await;
        })
        .await
        .unwrap();
    }
}
