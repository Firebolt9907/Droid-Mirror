//! A bounded, authenticated byte tunnel. Media framing and BLE input stay in the host apps.
use anyhow::{Context, Result};
use hmac::{Hmac, Mac};
use iroh::{
    Endpoint, EndpointId, SecretKey,
    endpoint::{Connection, RecvStream, RelayMode, SendStream, presets},
};
use iroh_mdns_address_lookup::MdnsAddressLookup;
use sha2::Sha256;
use std::{net::TcpListener, thread, time::Duration};
use tokio::{
    io::{AsyncRead, AsyncWrite, AsyncWriteExt},
    sync::oneshot,
};
use zeroize::Zeroize;

const ALPN: &[u8] = b"droidmirror/video/1";

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
        .secret_key(secret)
        .alpns(vec![ALPN.to_vec()])
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
    // End both directions on EOF/error; do not leave a video writer blocked after teardown.
    tokio::select! {
        result = async { tokio::io::copy(&mut input, &mut send).await?; send.finish()?; Ok::<_, anyhow::Error>(()) } => result?,
        result = async { tokio::io::copy(&mut recv, &mut output).await?; output.shutdown().await?; Ok::<_, anyhow::Error>(()) } => result?,
    }
    Ok(())
}

#[cfg(any(test, target_os = "android"))]
fn paired(conn: &Connection, expected: EndpointId) -> bool {
    if conn.remote_id() == expected {
        return true;
    }
    conn.close(1u32.into(), b"unpaired peer");
    false
}

async fn desktop(ep: Endpoint, peer: EndpointId, listener: TcpListener) -> Result<()> {
    listener.set_nonblocking(true)?;
    let listener = tokio::net::TcpListener::from_std(listener)?;
    let mut failures = 0;
    loop {
        let (socket, _) = listener.accept().await?;
        socket.set_nodelay(true)?;
        // One local consumer and one QUIC stream at a time; no unbounded task spawning.
        match tokio::time::timeout(Duration::from_secs(5), ep.connect(peer, ALPN)).await {
            Ok(Ok(conn)) => {
                diagnostic("Paired QUIC connection established over direct LAN");
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
    while let Some(incoming) = ep.accept().await {
        let Ok(Ok(conn)) = tokio::time::timeout(Duration::from_secs(5), incoming).await else {
            continue;
        };
        if !paired(&conn, peer) {
            diagnostic("Rejected unpaired QUIC identity");
            continue;
        }
        // This abstract socket is present only during an authenticated BLE capture session.
        let address = SocketAddr::from_abstract_name(b"droidmirror_video_upgrade")?;
        diagnostic("Paired Mac connected");
        // Do not open the application socket until the encrypted stream and its
        // preface are ready: opening it starts Android's two-second proof timer.
        let streams = match prepare_stream(&conn, false).await {
            Ok(streams) => streams,
            Err(error) => {
                diagnostic(&format!("Stream setup failed: {error:#}"));
                conn.close(0u32.into(), b"stream setup failed");
                continue;
            }
        };
        match UnixStream::connect_addr(&address) {
            Ok(socket) => {
                socket.set_nonblocking(true)?;
                let socket = tokio::net::UnixStream::from_std(socket)?;
                if let Err(error) = copy_stream(socket, streams.0, streams.1).await {
                    diagnostic(&format!("Video tunnel failed: {error:#}"));
                }
            }
            Err(error) => diagnostic(&format!("Local video endpoint failed: {error}")),
        }
        conn.close(0u32.into(), b"video disconnected");
    }
    Ok(())
}

pub struct Bridge {
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
    let runtime = tokio::runtime::Builder::new_multi_thread()
        .worker_threads(2)
        .enable_all()
        .build()?;
    let (stop, stopped) = oneshot::channel();
    let worker = thread::Builder::new().name("DroidMirrorIroh".into()).spawn(move || {
        runtime.block_on(async move {
            // Cancellation also covers bind/discovery, so teardown never waits for a network timeout.
            tokio::select! {
                _ = stopped => {},
                result = async {
                    let ep = endpoint(secret).await?;
                    if let Some(listener) = listener { desktop(ep, peer, listener).await }
                    else {
                        #[cfg(target_os = "android")]
                        { phone(ep, peer).await }
                        #[cfg(not(target_os = "android"))]
                        { anyhow::bail!("phone endpoint requires Android") }
                    }
                } => { if let Err(error) = result { diagnostic(&format!("Video transport stopped: {error:#}")); } }
            }
        });
        runtime.shutdown_timeout(Duration::from_secs(1));
    })?;
    Ok((
        Bridge {
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
        sys::jlong,
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
