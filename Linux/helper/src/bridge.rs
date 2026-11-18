//! Port of Native/ClassicBluetoothBridge.m for BlueZ.
//!
//! Protocol with the host (identical to the macOS helper):
//!   stdout: `LISTENING <video> <control>`, `READY <video> <control>`, `EVENT <NAME>`
//!   stdin:  `UPGRADE_PEER`, `UPGRADE <port>`, `UNLOCK_DECISION 0|1`
//! scrcpy connects to the loopback video/control ports with
//! `--external-video-port` / `--external-control-port`.

use crate::audio::{self, AudioLane};
use crate::ble_input::{self, Command, Event as BleEvent};
use crate::crypto;
use crate::queue::monotonic_secs;
use crate::wire::{Capabilities, Wire, WireSink};
use anyhow::{anyhow, Result};
use bluer::l2cap::{SeqPacket, Socket, SocketAddr};
use bluer::{Address, AddressType};
use std::io::{Read, Write};
use std::net::{Ipv4Addr, SocketAddrV4, TcpStream};
use std::sync::{Arc, Mutex};
use std::time::Duration;
use tokio::io::AsyncBufReadExt;
use tokio::net::TcpListener;
use tokio::sync::mpsc;

pub const PSM: u16 = 0xD001;

// Android Open Accessory bulk transport (Native/UsbAccessoryTransport.c).
unsafe extern "C" {
    fn dm_usb_start(port: *mut u16) -> *mut std::ffi::c_void;
    fn dm_usb_connected(context: *mut std::ffi::c_void) -> i32;
    fn dm_usb_stop(context: *mut std::ffi::c_void);
}
struct UsbHandle(*mut std::ffi::c_void);
unsafe impl Send for UsbHandle {}
const QUEUE_LIMIT: usize = 128 * 1024;

fn emit(line: &str) {
    let mut out = std::io::stdout().lock();
    let _ = writeln!(out, "{line}");
    let _ = out.flush();
}

#[derive(Default, Clone)]
struct Latency {
    values: [f64; 7],
    count: usize,
    next: usize,
}
impl Latency {
    fn add(&mut self, value: f64) {
        self.values[self.next % 7] = value;
        self.next += 1;
        self.count = (self.count + 1).min(7);
    }
    fn median(&self) -> f64 {
        let mut sorted = self.values[..self.count].to_vec();
        sorted.sort_by(|a, b| a.partial_cmp(b).unwrap());
        if self.count == 0 { 0.0 } else { sorted[self.count / 2] }
    }
}
#[derive(Default)]
struct Latencies {
    bluetooth: Latency,
    candidate: Latency,
}
impl Latencies {
    fn ready(&self) -> bool {
        self.bluetooth.count >= 3 && self.candidate.count >= 3
    }
    fn slower(&self) -> bool {
        self.ready() && self.candidate.median() > self.bluetooth.median() + 0.010
    }
}

/// Mutable session state; also the sink for every wire parser.
struct State {
    pending: Vec<u8>,
    control_pending: Vec<u8>,
    video_received: u64,
    video_packet: Vec<u8>,
    video_startup_remaining: usize,
    event_mask: u16,
    wifi_active: bool,
    wifi_nonce: Option<[u8; 32]>,
    peer_address_buffer: Vec<u8>,
    peer_addresses: Vec<[u8; 32]>,
    appearance_buffer: Vec<u8>,
    latencies: Arc<Mutex<Latencies>>,
    wireless_latency: bool,
    reported_tailscale: bool,
    pending_hints: Vec<[u8; 32]>,
    last_data: f64,
    /// Latest wireless audio state (bit 1 eligible, 2 sending, 4 failure).
    audio_state: u8,
    audio_state_changed: bool,
    /// Video currently arrives over USB: tells the renderer to skip its jitter delay.
    usb_video: bool,
}

impl State {
    fn record_latency(&mut self, timestamp: u64) {
        let delay = monotonic_secs() - timestamp as f64 / 1e9;
        let mut latencies = self.latencies.lock().unwrap();
        if self.wireless_latency {
            latencies.candidate.add(delay)
        } else {
            latencies.bluetooth.add(delay)
        }
    }
}

impl WireSink for State {
    fn video(&mut self, mut data: &[u8]) -> bool {
        self.video_received += data.len() as u64;
        while !data.is_empty() {
            if self.video_startup_remaining > 0 {
                let take = data.len().min(self.video_startup_remaining);
                self.pending.extend_from_slice(&data[..take]);
                self.video_startup_remaining -= take;
                data = &data[take..];
                continue;
            }
            let mut target = 12;
            if self.video_packet.len() >= 12 {
                let h = &self.video_packet;
                let size = u32::from_be_bytes(h[8..12].try_into().unwrap()) as usize;
                if h[0] & 0x80 == 0 {
                    if size == 0 || size > 8 * 1024 * 1024 {
                        return false;
                    }
                    target += size;
                }
            }
            let take = data.len().min(target - self.video_packet.len());
            self.video_packet.extend_from_slice(&data[..take]);
            data = &data[take..];
            if self.video_packet.len() < 12 {
                continue;
            }
            let h = &self.video_packet;
            let size = u32::from_be_bytes(h[8..12].try_into().unwrap()) as usize;
            if h[0] & 0x80 == 0 && self.video_packet.len() == 12 {
                if size == 0 || size > 8 * 1024 * 1024 {
                    return false;
                }
                continue;
            }
            if self.video_packet.len() == target {
                if self.pending.len() > QUEUE_LIMIT {
                    return false;
                }
                if self.video_packet[0] & 0x80 != 0 && self.usb_video {
                    // Local renderer extension (same as macOS): USB session flag.
                    self.video_packet[3] |= 2;
                }
                self.pending.append(&mut self.video_packet);
            }
        }
        true
    }
    fn event(&mut self, event: u8) {
        if event == 6 {
            return; // heartbeat
        }
        if event == 7 {
            emit("EVENT MINIMIZE_WINDOW");
            return;
        }
        if !(1..=10).contains(&event) {
            return;
        }
        let mask = 1u16 << (event - 1);
        if self.event_mask & mask != 0 {
            return;
        }
        self.event_mask |= mask;
        const NAMES: [&str; 10] = [
            "PHONE_ON", "SESSION_ENDED", "PHONE_LOCAL_USE", "STREAM_STARTED", "CAPTURE_FAILED",
            "ALIVE", "MINIMIZE_WINDOW", "PHONE_IN_USE", "PIN_PAUSED", "PIN_FAILED",
        ];
        emit(&format!("EVENT {}", NAMES[event as usize - 1]));
    }
    fn control(&mut self, bytes: &[u8]) -> bool {
        if bytes.len() > QUEUE_LIMIT - self.control_pending.len() {
            return false;
        }
        self.control_pending.extend_from_slice(bytes);
        true
    }
    fn setup(&mut self, bytes: &[u8]) -> bool {
        if bytes.len() > 32 - self.peer_address_buffer.len() {
            return false;
        }
        self.peer_address_buffer.extend_from_slice(bytes);
        if self.peer_address_buffer.len() < 32 {
            return true;
        }
        let record: [u8; 32] = std::mem::take(&mut self.peer_address_buffer).try_into().unwrap();
        if &record[..8] != b"DMIP0001" || ![0, 4, 16].contains(&record[8]) {
            return false;
        }
        if record[8] == 0 {
            self.peer_addresses.clear();
        } else {
            if record[25] == 0 && record[26] == 0 {
                return false;
            }
            if !self.peer_addresses.contains(&record) && self.peer_addresses.len() < 32 {
                self.peer_addresses.push(record);
            }
            let tailscale6 = [0xfd, 0x7a, 0x11, 0x5c, 0xa1, 0xe0];
            if !self.reported_tailscale
                && ((record[8] == 4 && record[9] == 100 && record[10] & 0xc0 == 0x40)
                    || (record[8] == 16 && record[9..15] == tailscale6))
            {
                eprintln!("Received Tailscale direct IP candidate over authenticated BLE");
                self.reported_tailscale = true;
            }
        }
        self.pending_hints.push(record);
        true
    }
    fn appearance(&mut self, bytes: &[u8]) -> bool {
        if bytes.len() > 16384 - self.appearance_buffer.len() {
            return false;
        }
        self.appearance_buffer.extend_from_slice(bytes);
        if bytes.last() == Some(&b'\n') {
            let Ok(value) = serde_json::from_slice::<serde_json::Value>(&self.appearance_buffer) else { return false };
            if !value.is_object() {
                return false;
            }
            if let Some(path) = std::env::var_os("DROIDMIRROR_APPEARANCE_CACHE") {
                let _ = std::fs::write(path, &self.appearance_buffer);
            }
            eprintln!("Phone appearance: received metadata ({} bytes)", self.appearance_buffer.len());
            self.appearance_buffer.clear();
        }
        true
    }
    fn latency(&mut self, timestamp: u64) {
        self.record_latency(timestamp);
    }
    fn reset_video(&mut self, offset: u64) -> bool {
        if self.wifi_active || self.wifi_nonce.is_none() || offset < self.video_received || self.video_startup_remaining > 0 {
            return false;
        }
        self.video_packet.clear();
        self.video_received = offset;
        true
    }
    fn audio(&mut self, kind: u8, bytes: &[u8]) -> bool {
        // State arrives on the video lane after this helper opted in (command 4);
        // PCM uses its own authenticated lane (audio.rs).
        if kind == 6 {
            if bytes.len() != 1 || bytes[0] > 7 {
                return false;
            }
            if bytes[0] != self.audio_state {
                self.audio_state = bytes[0];
                self.audio_state_changed = true;
            }
        }
        true
    }
}

struct Probe {
    socket: Option<TcpStream>,
    valid: bool,
    initial: bool,
    cutoff: u64,
    nonce: Option<[u8; 32]>,
    is_peer: bool,
}

fn read_exact(stream: &mut TcpStream, bytes: &mut [u8]) -> bool {
    stream.read_exact(bytes).is_ok()
}

/// Authenticated video handoff to a loopback port (Iroh peer bridge or an
/// `adb forward` to `localabstract:droidmirror_video_upgrade`).
fn probe_wireless(port: u16, is_peer: bool, key: [u8; 32], profile: Vec<u8>, latencies: Arc<Mutex<Latencies>>) -> Probe {
    let mut result = Probe { socket: None, valid: false, initial: false, cutoff: 0, nonce: None, is_peer };
    let Ok(mut fd) = TcpStream::connect_timeout(&SocketAddrV4::new(Ipv4Addr::LOCALHOST, port).into(), Duration::from_secs(2)) else {
        return result;
    };
    let wait = Duration::from_secs(if is_peer { 20 } else { 2 });
    let _ = fd.set_read_timeout(Some(wait));
    let _ = fd.set_write_timeout(Some(wait));
    let mut hello = [0u8; 40];
    if !read_exact(&mut fd, &mut hello) || (&hello[..8] != b"DMWIFI05" && &hello[..8] != b"DMWIFI06") {
        return result;
    }
    let nonce: [u8; 32] = hello[8..40].try_into().unwrap();
    result.nonce = Some(nonce);
    let mut request = profile.clone();
    request.extend_from_slice(&crypto::upgrade_proof(&key, "client", &nonce, &profile));
    if fd.write_all(&request).is_err() {
        return result;
    }
    let mut preview = [0u8; 32];
    if !read_exact(&mut fd, &mut preview) || !crypto::equal(&preview, &crypto::upgrade_proof(&key, "preview server", &nonce, &profile)) {
        return result;
    }
    let started = monotonic_secs();
    let (mut frames, mut confirmed, mut saw_video, mut warmed, mut initial) = (0usize, false, false, false, false);
    let mut video = vec![0u8; 8192];
    while monotonic_secs() - started < 10.0 {
        let mut length = [0u8; 4];
        if !read_exact(&mut fd, &mut length) {
            break;
        }
        let length = i32::from_be_bytes(length);
        if length == -3 && &hello[..8] == b"DMWIFI06" {
            initial = true;
            warmed = true;
            break;
        }
        if length == -2 {
            let mut timestamp = [0u8; 8];
            if !read_exact(&mut fd, &mut timestamp) {
                break;
            }
            let delay = monotonic_secs() - u64::from_be_bytes(timestamp) as f64 / 1e9;
            latencies.lock().unwrap().candidate.add(delay);
            continue;
        }
        if length == -1 {
            warmed = confirmed;
            break;
        }
        if !(0..=8192).contains(&length) {
            break;
        }
        if length > 0 && !read_exact(&mut fd, &mut video[..length as usize]) {
            break;
        }
        if length > 0 {
            saw_video = true;
        } else if saw_video {
            frames += 1;
            saw_video = false;
        }
        if !confirmed && frames >= 3 && monotonic_secs() - started >= 0.25 {
            let acceptable = {
                let l = latencies.lock().unwrap();
                !is_peer || (l.ready() && !l.slower())
            };
            if !acceptable {
                if !latencies.lock().unwrap().ready() {
                    continue;
                }
                eprintln!("Direct IP video is slower than Bluetooth or lacks latency samples; keeping Bluetooth");
                break;
            }
            if fd.write_all(&[1]).is_err() {
                break;
            }
            confirmed = true;
        }
    }
    let mut response = [0u8; 48];
    if warmed && read_exact(&mut fd, &mut response) {
        let mut authenticated = profile.clone();
        authenticated.extend_from_slice(&response[..8]);
        let expected = crypto::upgrade_proof(&key, if initial { "initial server" } else { "server" }, &nonce, &authenticated);
        let cutoff = u64::from_be_bytes(response[..8].try_into().unwrap());
        result.valid = crypto::equal(&expected, &response[8..40]) && (!initial || cutoff == 0) && &response[40..48] == b"DMBT0006";
        result.cutoff = cutoff;
        result.initial = initial;
    }
    if result.valid {
        result.socket = Some(fd);
    }
    result
}

struct PeerHandle(*mut std::ffi::c_void);
unsafe impl Send for PeerHandle {}

pub struct Bridge {
    address: Address,
    key: [u8; 32],
    st: State,
    wire: Wire,
    return_wire: Wire,
    wifi_wire: Option<Wire>,
    profile: Vec<u8>,
    ble: Option<ble_input::Handle>,
    l2cap_ready: bool,
    announced_ready: bool,
    video_port: u16,
    control_port: u16,
    outgoing: Vec<u8>,
    last_heartbeat: f64,
    last_ack: u64,
    pending_since: f64,
    control_since: f64,
    unlock_requested_at: f64,
    unlock_resolved: bool,
    peer: Option<PeerHandle>,
    peer_port: u16,
    probing: bool,
    wifi: Option<std::net::TcpStream>,
    wifi_is_peer: bool,
    wifi_initial: bool,
    wifi_recovering: bool,
    wifi_recovery_requested: f64,
    wifi_cutoff: u64,
    wifi_pending_since: f64,
    wifi_last_data: f64,
    latency_bad_since: f64,
    latency_retry_after: f64,
    video_probe_attempts: usize,
    stage: String,
    audio: Option<AudioLane>,
    audio_forwards: std::collections::HashMap<u16, u16>,
    wifi_port: u16,
    peer_audio_port: u16,
    tx: Option<mpsc::UnboundedSender<Input>>,
    usb: Option<UsbHandle>,
    usb_port: u16,
    wifi_is_usb: bool,
}

impl Drop for Bridge {
    fn drop(&mut self) {
        if let Some(usb) = self.usb.take() {
            unsafe { dm_usb_stop(usb.0) };
        }
        if let Some(handle) = self.peer.take() {
            unsafe { droidmirror_peer::dm_peer_stop(handle.0.cast()) };
        }
        self.key.fill(0);
    }
}

enum Input {
    Classic(Result<Vec<u8>>),
    Ble(BleEvent),
    Stdin(Option<String>),
    Probe(Probe),
    AudioEnded(bool),
    Tick,
}

impl Bridge {
    pub fn new(address: Address, key: [u8; 32]) -> Self {
        let env_int = |name: &str, default: i64| std::env::var(name).ok().and_then(|v| v.parse().ok()).unwrap_or(default);
        let mut max_size = env_int("DROIDMIRROR_WIFI_MAX_SIZE", 1920);
        let mut fps = env_int("DROIDMIRROR_WIFI_FPS", 60);
        let mut bit_rate = env_int("DROIDMIRROR_WIFI_BIT_RATE", 12_000_000);
        if max_size != 0 && !(128..=8192).contains(&max_size) {
            max_size = 1920;
        }
        if !(1..=240).contains(&fps) {
            fps = 60;
        }
        if !(256_000..=64_000_000).contains(&bit_rate) {
            bit_rate = 12_000_000;
        }
        let mut profile = Vec::new();
        for value in [max_size, fps, bit_rate] {
            profile.extend_from_slice(&(value as u32).to_be_bytes());
        }
        let mut return_wire = Wire::new(Capabilities { control: true, setup: true, ..Default::default() });
        let mut st = State {
            pending: Vec::new(),
            control_pending: Vec::new(),
            video_received: 0,
            video_packet: Vec::new(),
            video_startup_remaining: 69,
            event_mask: 0,
            wifi_active: false,
            wifi_nonce: None,
            peer_address_buffer: Vec::new(),
            peer_addresses: Vec::new(),
            appearance_buffer: Vec::new(),
            latencies: Arc::new(Mutex::new(Latencies::default())),
            wireless_latency: false,
            reported_tailscale: false,
            pending_hints: Vec::new(),
            last_data: monotonic_secs(),
            audio_state: 0,
            audio_state_changed: false,
            usb_video: false,
        };
        return_wire.feed(b"DMBT0005", &mut st);
        Bridge {
            address,
            key,
            st,
            wire: Wire::video_only(Capabilities { appearance: true, reset_video: true, ..Default::default() }),
            return_wire,
            wifi_wire: None,
            profile,
            ble: None,
            l2cap_ready: false,
            announced_ready: false,
            video_port: 0,
            control_port: 0,
            outgoing: Vec::new(),
            last_heartbeat: 0.0,
            last_ack: 0,
            pending_since: 0.0,
            control_since: 0.0,
            unlock_requested_at: 0.0,
            unlock_resolved: false,
            peer: None,
            peer_port: 0,
            probing: false,
            wifi: None,
            wifi_is_peer: false,
            wifi_initial: false,
            wifi_recovering: false,
            wifi_recovery_requested: 0.0,
            wifi_cutoff: 0,
            wifi_pending_since: 0.0,
            wifi_last_data: 0.0,
            latency_bad_since: 0.0,
            latency_retry_after: 0.0,
            video_probe_attempts: 0,
            stage: "initializing BlueZ".into(),
            audio: None,
            audio_forwards: std::collections::HashMap::new(),
            wifi_port: 0,
            peer_audio_port: 0,
            tx: None,
            usb: None,
            usb_port: 0,
            wifi_is_usb: false,
        }
    }

    fn unlock_policy() -> i8 {
        match std::env::var("DROIDMIRROR_ALLOW_UNLOCK").as_deref() {
            Ok("defer") => -1,
            Ok("1") => 1,
            _ => 0,
        }
    }

    pub async fn run(mut self) -> Result<()> {
        let session = bluer::Session::new().await.map_err(|e| anyhow!("BlueZ is unavailable: {e}"))?;
        let adapter = session.default_adapter().await.map_err(|e| anyhow!("No Bluetooth adapter: {e}"))?;
        if !adapter.is_powered().await.unwrap_or(false) {
            return Err(anyhow!("Turn on Bluetooth on this computer."));
        }
        let device = adapter.device(self.address)?;
        if !device.is_paired().await.unwrap_or(false) {
            return Err(anyhow!("Pair the phone in your system Bluetooth settings first"));
        }

        let video_listener = TcpListener::bind((Ipv4Addr::LOCALHOST, 0)).await?;
        let control_listener = TcpListener::bind((Ipv4Addr::LOCALHOST, 0)).await?;
        self.video_port = video_listener.local_addr()?.port();
        self.control_port = control_listener.local_addr()?.port();
        emit(&format!("LISTENING {} {}", self.video_port, self.control_port));

        let (tx, mut rx) = mpsc::unbounded_channel::<Input>();
        self.tx = Some(tx.clone());
        let (ble_tx, mut ble_rx) = mpsc::unbounded_channel::<BleEvent>();
        {
            let tx = tx.clone();
            tokio::spawn(async move {
                while let Some(event) = ble_rx.recv().await {
                    if tx.send(Input::Ble(event)).is_err() {
                        break;
                    }
                }
            });
        }
        {
            let tx = tx.clone();
            tokio::spawn(async move {
                let mut lines = tokio::io::BufReader::new(tokio::io::stdin()).lines();
                loop {
                    let line = lines.next_line().await.ok().flatten();
                    let end = line.is_none();
                    if tx.send(Input::Stdin(line)).is_err() || end {
                        break;
                    }
                }
            });
        }
        {
            let tx = tx.clone();
            tokio::spawn(async move {
                let mut tick = tokio::time::interval(Duration::from_millis(20));
                loop {
                    tick.tick().await;
                    if tx.send(Input::Tick).is_err() {
                        break;
                    }
                }
            });
        }
        // Classic baseband + L2CAP video channel (phone to laptop only).
        {
            let tx = tx.clone();
            let address = self.address;
            tokio::spawn(async move {
                eprintln!("Opening Classic L2CAP PSM 0x{PSM:04x}");
                let connected = async {
                    let socket = Socket::<SeqPacket>::new_seq_packet()?;
                    socket.set_security(bluer::l2cap::Security { level: bluer::l2cap::SecurityLevel::Medium, key_size: 0 })?;
                    let _ = socket.set_recv_mtu(16384);
                    socket.connect(SocketAddr::new(address, AddressType::BrEdr, PSM)).await
                }
                .await;
                let channel = match connected {
                    Ok(channel) => channel,
                    Err(error) => {
                        let _ = tx.send(Input::Classic(Err(anyhow!(
                            "Could not open Classic L2CAP ({error}). Enable the background bridge, select this computer and authorize Shizuku on Android."
                        ))));
                        return;
                    }
                };
                eprintln!(
                    "Classic L2CAP connected; RX MTU={} TX MTU={}",
                    channel.recv_mtu().unwrap_or(0),
                    channel.send_mtu().unwrap_or(0)
                );
                let _ = tx.send(Input::Classic(Ok(Vec::new())));
                let mut buffer = vec![0u8; 65536];
                loop {
                    match channel.recv(&mut buffer).await {
                        Ok(0) => {
                            let _ = tx.send(Input::Classic(Err(anyhow!("Bluetooth stream closed. Reconnect from your computer."))));
                            return;
                        }
                        Ok(n) => {
                            if tx.send(Input::Classic(Ok(buffer[..n].to_vec()))).is_err() {
                                return;
                            }
                        }
                        Err(error) => {
                            let _ = tx.send(Input::Classic(Err(anyhow!("Classic video stream read failed: {error}"))));
                            return;
                        }
                    }
                }
            });
        }
        self.stage = "opening the Android Classic L2CAP channel".into();
        if std::env::var("DROIDMIRROR_USB").as_deref() != Ok("0") {
            let mut port = 0u16;
            let handle = unsafe { dm_usb_start(&mut port) };
            if !handle.is_null() && port != 0 {
                self.usb = Some(UsbHandle(handle));
                self.usb_port = port;
            }
        }
        self.probe_peer(&tx);

        let mut video_client: Option<tokio::net::TcpStream> = None;
        let mut control_client: Option<tokio::net::TcpStream> = None;
        let mut sigterm = tokio::signal::unix::signal(tokio::signal::unix::SignalKind::terminate())?;

        loop {
            let mut control_buffer = [0u8; 4096];
            let control_read = async {
                match control_client.as_ref() {
                    Some(client) => {
                        client.readable().await.ok();
                        match client.try_read(&mut control_buffer) {
                            Ok(n) => Some(n),
                            Err(error) if error.kind() == std::io::ErrorKind::WouldBlock => None,
                            Err(_) => Some(0),
                        }
                    }
                    None => std::future::pending().await,
                }
            };
            tokio::select! {
                _ = sigterm.recv() => {
                    eprintln!("Closing Bluetooth session before helper termination");
                    if let Some(ble) = &self.ble { ble.close(); }
                    return Ok(());
                }
                accepted = video_listener.accept(), if video_client.is_none() => {
                    if let Ok((stream, _)) = accepted { let _ = stream.set_nodelay(true); video_client = Some(stream); }
                }
                accepted = control_listener.accept(), if control_client.is_none() => {
                    if let Ok((stream, _)) = accepted {
                        let _ = stream.set_nodelay(true);
                        control_client = Some(stream);
                        // scrcpy's external control bridge waits for one dummy byte.
                        self.st.control_pending.push(0);
                        if self.control_since == 0.0 { self.control_since = monotonic_secs(); }
                    }
                }
                read = control_read => {
                    match read {
                        Some(0) => return Err(anyhow!("Control client closed")),
                        Some(n) => {
                            if n + 5 > QUEUE_LIMIT - self.outgoing.len() { return Err(anyhow!("Bluetooth input backlog exceeded")); }
                            self.outgoing.push(0);
                            self.outgoing.extend_from_slice(&(n as u32).to_be_bytes());
                            self.outgoing.extend_from_slice(&control_buffer[..n]);
                            self.send_control()?;
                        }
                        None => {}
                    }
                }
                input = rx.recv() => {
                    let Some(input) = input else { return Ok(()) };
                    match input {
                        Input::Classic(Err(error)) => return Err(error),
                        Input::Classic(Ok(bytes)) => {
                            self.st.last_data = monotonic_secs();
                            if bytes.is_empty() {
                                self.l2capReady();
                            } else {
                                if self.wifi_recovering {
                                    self.wifi_recovering = false;
                                    emit("EVENT BLUETOOTH_ACTIVE");
                                }
                                self.st.wireless_latency = false;
                                if !self.wire.feed(&bytes, &mut self.st) {
                                    return Err(anyhow!("Invalid Bluetooth stream or video backlog exceeded; update the Android companion and DroidMirror"));
                                }
                                self.start_ble_when_ready(&adapter, &ble_tx);
                            }
                        }
                        Input::Ble(BleEvent::Ready) => { self.announce_ready(); self.send_control()?; }
                        Input::Ble(BleEvent::Failed(reason)) => return Err(anyhow!(reason)),
                        Input::Ble(BleEvent::Received(bytes)) => {
                            self.st.last_data = monotonic_secs();
                            if !self.return_wire.feed(&bytes, &mut self.st) {
                                return Err(anyhow!("Invalid BLE control or event stream."));
                            }
                            self.flush_hints();
                        }
                        Input::Stdin(None) => {
                            // Host went away: end the session gracefully.
                            if let Some(ble) = &self.ble { ble.close(); }
                            return Ok(());
                        }
                        Input::Stdin(Some(line)) => self.command(&line, &tx),
                        Input::Probe(probe) => self.finish_probe(probe, &adapter, &ble_tx)?,
                        Input::AudioEnded(failed) => {
                            self.audio = None;
                            emit(if failed { "EVENT AUDIO_FAILED" } else { "EVENT AUDIO_STOPPED" });
                        }
                        Input::Tick => self.tick(&tx)?,
                    }
                }
            }
            // Flush video and control replies to scrcpy without blocking the loop.
            if let Some(client) = &video_client {
                while !self.st.pending.is_empty() {
                    match client.try_write(&self.st.pending) {
                        Ok(0) => return Err(anyhow!("Video client disconnected")),
                        Ok(n) => {
                            self.st.pending.drain(..n);
                        }
                        Err(error) if error.kind() == std::io::ErrorKind::WouldBlock => break,
                        Err(_) => return Err(anyhow!("Video client disconnected")),
                    }
                }
                let mut probe = [0u8; 1];
                match client.try_read(&mut probe) {
                    Ok(_) => return Err(anyhow!("Video client closed")),
                    Err(error) if error.kind() == std::io::ErrorKind::WouldBlock => {}
                    Err(_) => return Err(anyhow!("Video client closed")),
                }
            }
            if self.st.pending.is_empty() {
                self.pending_since = 0.0;
            } else if self.pending_since == 0.0 {
                self.pending_since = monotonic_secs();
            }
            if let Some(client) = &control_client {
                while !self.st.control_pending.is_empty() {
                    match client.try_write(&self.st.control_pending) {
                        Ok(0) => return Err(anyhow!("Control client disconnected")),
                        Ok(n) => {
                            self.st.control_pending.drain(..n);
                        }
                        Err(error) if error.kind() == std::io::ErrorKind::WouldBlock => break,
                        Err(_) => return Err(anyhow!("Control client disconnected")),
                    }
                }
            }
            if self.st.control_pending.is_empty() {
                self.control_since = 0.0;
            } else if self.control_since == 0.0 && control_client.is_some() {
                self.control_since = monotonic_secs();
            }
        }
    }

    #[allow(non_snake_case)]
    fn l2capReady(&mut self) {
        self.l2cap_ready = true;
        self.stage = "waiting for Android to accept the Classic session".into();
    }

    fn start_ble_when_ready(&mut self, adapter: &bluer::Adapter, ble_tx: &mpsc::UnboundedSender<BleEvent>) {
        // The validated Classic header or authenticated initial LAN handoff is
        // evidence that Android created its per-session BLE service.
        if self.ble.is_some() || (!(self.l2cap_ready && self.wire.decided) && !self.wifi_initial) {
            return;
        }
        eprintln!("Android accepted mirror session; starting BLE discovery");
        self.stage = "authenticating the paired BLE side channel".into();
        self.st.last_data = monotonic_secs();
        self.ble = Some(ble_input::start(adapter.clone(), self.address, self.key, Self::unlock_policy(), ble_tx.clone()));
    }

    fn announce_ready(&mut self) {
        let ble_ready = self.ble.as_ref().is_some_and(|b| b.status.ready.load(std::sync::atomic::Ordering::SeqCst));
        if self.announced_ready || (!self.l2cap_ready && !self.wifi_initial) || !ble_ready {
            return;
        }
        self.announced_ready = true;
        emit(&format!("READY {} {}", self.video_port, self.control_port));
        eprintln!("BLE side channel authenticated; Classic L2CAP carries video only (phone to computer)");
        if self.unlock_requested_at == 0.0 && self.ble.as_ref().is_some_and(|b| b.status.awaiting_unlock_decision()) {
            self.unlock_requested_at = monotonic_secs();
            eprintln!("Authenticated capture channel open; waiting for the host unlock decision");
            emit("EVENT UNLOCK_DECISION_NEEDED");
        }
    }

    fn resolve_unlock(&mut self, allowed: bool, reason: &str) {
        if self.unlock_requested_at == 0.0 || self.unlock_resolved {
            return;
        }
        self.unlock_resolved = true;
        eprintln!("Unlock decision {} ({reason})", if allowed { "allowed" } else { "manual" });
        if let Some(ble) = &self.ble {
            ble.resolve_unlock(allowed);
        }
    }

    fn send_control(&mut self) -> Result<()> {
        let Some(ble) = &self.ble else { return Ok(()) };
        if !ble.usable() || self.outgoing.is_empty() {
            return Ok(());
        }
        if !ble.send(Command::Send(std::mem::take(&mut self.outgoing))) {
            return Err(anyhow!("BLE input backlog exceeded"));
        }
        Ok(())
    }

    fn start_audio(&mut self) {
        if self.audio.is_some() || !self.st.wifi_active || self.st.audio_state & 1 == 0 {
            emit("EVENT AUDIO_FAILED");
            return;
        }
        // Prefer the paired QUIC audio port; an ADB video session may use its audio forward.
        let mut ports = vec![self.peer_audio_port];
        if !self.wifi_is_peer {
            ports.push(*self.audio_forwards.get(&self.wifi_port).unwrap_or(&0));
        }
        let buffer = std::env::var("DROIDMIRROR_AUDIO_BUFFER_MS").ok().and_then(|v| v.parse().ok()).unwrap_or(120);
        for port in ports.into_iter().filter(|p| *p != 0) {
            let tx = self.tx.clone();
            if let Some(lane) = audio::start(port, self.key, buffer, move |failed| {
                if let Some(tx) = tx {
                    let _ = tx.send(Input::AudioEnded(failed));
                }
            }) {
                eprintln!("Independent audio lane authenticated");
                self.audio = Some(lane);
                emit("EVENT AUDIO_PLAYING");
                return;
            }
        }
        emit("EVENT AUDIO_FAILED");
    }

    fn stop_audio(&mut self) {
        if let Some(lane) = self.audio.take() {
            lane.stop();
        }
    }

    fn command(&mut self, line: &str, tx: &mpsc::UnboundedSender<Input>) {
        match line.trim() {
            "UPGRADE_PEER" => self.probe_peer(tx),
            "AUDIO_START" => self.start_audio(),
            "AUDIO_STOP" => self.stop_audio(),
            "UNLOCK_DECISION 1" => self.resolve_unlock(true, "host approved"),
            "UNLOCK_DECISION 0" => self.resolve_unlock(false, "host declined"),
            other => {
                if let Some(rest) = other.strip_prefix("AUDIO_FORWARD ") {
                    let ports: Vec<u16> = rest.split_whitespace().filter_map(|p| p.parse().ok()).collect();
                    if ports.len() == 2 && ports[0] != 0 && ports[1] != 0 {
                        self.audio_forwards.insert(ports[0], ports[1]);
                    }
                }
                if let Some(port) = other.strip_prefix("UPGRADE ").and_then(|p| p.parse::<u16>().ok()) {
                    if port > 0 {
                        self.probe(port, false, tx);
                    }
                }
            }
        }
    }

    fn flush_hints(&mut self) {
        let hints = std::mem::take(&mut self.st.pending_hints);
        if let Some(handle) = &self.peer {
            for record in hints {
                let port = u16::from_be_bytes([record[25], record[26]]);
                unsafe { droidmirror_peer::dm_peer_add_address(handle.0.cast(), record[8], record[9..].as_ptr(), port) };
            }
        }
    }

    fn usb_connected(&self) -> bool {
        self.usb.as_ref().is_some_and(|usb| unsafe { dm_usb_connected(usb.0) } != 0)
    }

    /// USB is preferred whenever an accessory link is up (as on macOS).
    fn poll_usb(&mut self, tx: &mpsc::UnboundedSender<Input>) -> Result<()> {
        if !self.usb_connected() || self.probing {
            return Ok(());
        }
        if self.wifi.is_some() {
            if !self.wifi_is_usb && self.st.wifi_active {
                return self.fallback_to_bluetooth();
            }
            return Ok(());
        }
        if !self.wifi_recovering {
            self.probe(self.usb_port, false, tx);
        }
        Ok(())
    }

    fn probe_peer(&mut self, tx: &mpsc::UnboundedSender<Input>) {
        if self.wifi.is_some() || self.wifi_recovering || self.probing {
            return;
        }
        if self.usb_connected() {
            return;
        }
        if self.peer.is_none() {
            let key = self.key;
            // The peer library owns its own runtime; never start it on a Tokio worker.
            let started = std::thread::spawn(move || {
                let mut port = 0u16;
                let handle = unsafe { droidmirror_peer::dm_peer_start(key.as_ptr(), &mut port) };
                (PeerHandle(handle.cast()), port)
            })
            .join();
            match started {
                Ok((handle, port)) if !handle.0.is_null() && port != 0 => {
                    self.peer_audio_port = unsafe { droidmirror_peer::dm_peer_audio_port(handle.0.cast()) };
                    self.peer = Some(handle);
                    self.peer_port = port;
                    let records = self.st.peer_addresses.clone();
                    self.st.pending_hints.extend(records);
                    self.flush_hints();
                }
                _ => {
                    emit("EVENT LAN_UNAVAILABLE");
                    return;
                }
            }
        }
        if monotonic_secs() < self.latency_retry_after {
            emit("EVENT LAN_UNAVAILABLE");
            return;
        }
        self.probe(self.peer_port, true, tx);
    }

    fn probe(&mut self, port: u16, is_peer: bool, tx: &mpsc::UnboundedSender<Input>) {
        if self.probing || self.wifi.is_some() || self.wifi_recovering {
            return;
        }
        self.probing = true;
        self.wifi_port = port;
        self.st.latencies.lock().unwrap().candidate = Latency::default();
        self.latency_bad_since = 0.0;
        if self.video_probe_attempts < 3 {
            eprintln!("Trying {} video", if is_peer { "direct IP (LAN/VPN)" } else { "wireless ADB" });
        }
        self.video_probe_attempts += 1;
        let (key, profile, latencies, tx) = (self.key, self.profile.clone(), self.st.latencies.clone(), tx.clone());
        tokio::task::spawn_blocking(move || {
            let probe = probe_wireless(port, is_peer, key, profile, latencies);
            let _ = tx.send(Input::Probe(probe));
        });
    }

    fn finish_probe(&mut self, probe: Probe, adapter: &bluer::Adapter, ble_tx: &mpsc::UnboundedSender<BleEvent>) -> Result<()> {
        self.probing = false;
        let Some(socket) = probe.socket.filter(|_| probe.valid) else {
            // A response can be lost after the phone committed; a BLE request is harmless otherwise.
            if let (Some(ble), Some(nonce)) = (&self.ble, probe.nonce) {
                if ble.status.ready.load(std::sync::atomic::Ordering::SeqCst) {
                    ble.send(Command::RequestBluetoothVideo(self.st.video_received, nonce));
                }
            }
            if probe.is_peer {
                emit("EVENT LAN_UNAVAILABLE");
            }
            return Ok(());
        };
        if probe.cutoff < self.st.video_received {
            return Err(anyhow!("Invalid Wi-Fi video cutoff"));
        }
        socket.set_nonblocking(true)?;
        let _ = socket.set_nodelay(true);
        let usb = self.usb_port != 0 && self.wifi_port == self.usb_port;
        eprintln!("Video handoff authenticated over {}", if usb { "USB accessory" } else if probe.is_peer { "direct IP (LAN/VPN)" } else { "wireless ADB" });
        self.wifi_is_usb = usb;
        self.wifi_is_peer = probe.is_peer;
        self.wifi_initial = probe.initial;
        self.st.wifi_nonce = probe.nonce;
        self.wifi_cutoff = probe.cutoff;
        let now = monotonic_secs();
        self.wifi_last_data = now;
        self.wifi_pending_since = now;
        self.wifi = Some(socket);
        let mut wire = Wire::video_only(Capabilities { appearance: true, audio: true, ..Default::default() });
        if !wire.feed(b"DMBT0006", &mut self.st) {
            return Err(anyhow!("Invalid wireless video header"));
        }
        self.wifi_wire = Some(wire);
        self.start_ble_when_ready(adapter, ble_tx);
        Ok(())
    }

    fn fallback_to_bluetooth(&mut self) -> Result<()> {
        self.stop_audio();
        if self.st.audio_state != 0 {
            self.st.audio_state = 0;
            self.st.audio_state_changed = true;
        }
        self.st.wifi_active = false;
        self.st.usb_video = false;
        self.wifi_is_usb = false;
        self.wifi = None;
        self.wifi_wire = None;
        self.wifi_recovering = true;
        self.wifi_recovery_requested = monotonic_secs();
        emit("EVENT WIFI_RECOVERING");
        let nonce = self.st.wifi_nonce.unwrap_or([0; 32]);
        if !self.ble.as_ref().is_some_and(|b| b.send(Command::RequestBluetoothVideo(self.st.video_received, nonce))) {
            return Err(anyhow!("BLE video recovery request failed"));
        }
        eprintln!("Peer video dropped; requested Bluetooth video over BLE");
        Ok(())
    }

    fn poll_wifi(&mut self) -> Result<()> {
        let now = monotonic_secs();
        if self.wifi.is_none() {
            if self.wifi_recovering && now - self.wifi_recovery_requested >= 1.0 {
                self.wifi_recovery_requested = now;
                let nonce = self.st.wifi_nonce.unwrap_or([0; 32]);
                if !self.ble.as_ref().is_some_and(|b| b.send(Command::RequestBluetoothVideo(self.st.video_received, nonce))) {
                    return Err(anyhow!("BLE video recovery request failed"));
                }
            }
            return Ok(());
        }
        if self.wifi_is_peer && self.latency_bad_since > 0.0 && now - self.latency_bad_since >= 2.0 {
            eprintln!("Direct IP video delivery is slower than Bluetooth; recovering Bluetooth");
            self.latency_retry_after = now + 60.0;
            return self.fallback_to_bluetooth();
        }
        if now - self.wifi_last_data > if self.announced_ready { 4.0 } else { 15.0 } {
            eprintln!("Peer video stalled: queued={} received={}", self.st.pending.len(), self.st.video_received);
            return self.fallback_to_bluetooth();
        }
        if !self.st.wifi_active {
            if self.st.video_received != self.wifi_cutoff {
                if now - self.wifi_pending_since > 3.0 {
                    return self.fallback_to_bluetooth();
                }
                return Ok(());
            }
            if !self.wifi_initial && !self.wire.complete() {
                return Err(anyhow!("Wi-Fi handoff split a Bluetooth record"));
            }
            let ready = if self.wifi_is_usb { 2u8 } else { 1u8 };
            let socket = self.wifi.as_mut().unwrap();
            match socket.write(&[ready]) {
                Ok(1) => {}
                Err(error) if error.kind() == std::io::ErrorKind::WouldBlock => return Ok(()),
                _ => return self.fallback_to_bluetooth(),
            }
            self.st.wifi_active = true;
            // Opt into audio state records (older phones ignore this).
            let _ = self.wifi.as_mut().unwrap().write(&[4]);
            self.st.usb_video = self.wifi_is_usb;
            emit(if self.wifi_is_usb { "EVENT USB_ACTIVE" } else { "EVENT WIFI_ACTIVE" });
        }
        let mut total = 0;
        let mut buffer = [0u8; 16384];
        while total < 512 * 1024 && self.st.pending.len() < QUEUE_LIMIT {
            let capacity = 16384.min(QUEUE_LIMIT - self.st.pending.len());
            let socket = self.wifi.as_mut().unwrap();
            match socket.read(&mut buffer[..capacity]) {
                Ok(0) => {
                    eprintln!("Peer video socket ended");
                    return self.fallback_to_bluetooth();
                }
                Ok(n) => {
                    self.wifi_last_data = monotonic_secs();
                    self.st.wireless_latency = true;
                    let wire = self.wifi_wire.as_mut().unwrap();
                    if !wire.feed(&buffer[..n], &mut self.st) {
                        return Err(anyhow!("Invalid wireless video stream"));
                    }
                    self.st.wireless_latency = false;
                    total += n;
                }
                Err(error) if error.kind() == std::io::ErrorKind::WouldBlock || error.kind() == std::io::ErrorKind::Interrupted => break,
                Err(error) => {
                    eprintln!("Peer video socket ended: {error}");
                    return self.fallback_to_bluetooth();
                }
            }
        }
        if self.wifi_is_peer && self.st.wifi_active {
            if self.st.latencies.lock().unwrap().slower() {
                if self.latency_bad_since == 0.0 {
                    self.latency_bad_since = now;
                }
            } else {
                self.latency_bad_since = 0.0;
            }
        }
        Ok(())
    }

    fn tick(&mut self, _tx: &mpsc::UnboundedSender<Input>) -> Result<()> {
        let now = monotonic_secs();
        if self.st.audio_state_changed {
            self.st.audio_state_changed = false;
            emit(&format!("EVENT AUDIO_STATE {}", self.st.audio_state));
            if self.st.audio_state & 1 == 0 || self.st.audio_state & 4 != 0 {
                self.stop_audio();
            }
        }
        if self.unlock_requested_at > 0.0 && !self.unlock_resolved {
            // Video cannot start before the decision; the host prompt is not a stall.
            self.st.last_data = now;
            self.wifi_last_data = now;
            if now - self.unlock_requested_at > 30.0 {
                self.resolve_unlock(false, "timed out; unlock manually");
            }
        }
        self.poll_wifi()?;
        if let Some(tx) = self.tx.clone() {
            self.poll_usb(&tx)?;
        }
        // Acknowledge video: fast while moving, heartbeat cadence when idle.
        let moving = self.st.video_received != self.last_ack;
        let interval = if moving { 0.04 } else { 0.25 };
        if (self.l2cap_ready || self.wifi_initial) && now - self.last_heartbeat >= interval {
            if let Some(ble) = &self.ble {
                if ble.status.ready.load(std::sync::atomic::Ordering::SeqCst) {
                    if !ble.send(Command::AcknowledgeVideo(self.st.video_received)) {
                        return Err(anyhow!("BLE video acknowledgement failed"));
                    }
                    self.last_ack = self.st.video_received;
                    self.last_heartbeat = now;
                }
            }
        }
        if self.pending_since > 0.0 && now - self.pending_since > 1.0 {
            return Err(anyhow!("Video bridge stalled for one second; reconnect"));
        }
        if self.control_since > 0.0 && now - self.control_since > 1.0 {
            return Err(anyhow!("Control response stalled"));
        }
        if now - self.st.last_data > 15.0 {
            if let Some(ble) = &self.ble {
                let s = &ble.status;
                if s.proof_rejected.load(std::sync::atomic::Ordering::SeqCst) && !ble.usable() {
                    return Err(anyhow!(
                        "PAIRING_CODE_MISMATCH: Pairing code is wrong. Copy the code for this computer from the Android companion and save it again in DroidMirror."
                    ));
                }
                if !ble.usable() {
                    return Err(anyhow!("Bluetooth timed out while {} ({})", self.stage, s.stage()));
                }
            }
            return Err(anyhow!("Bluetooth timed out while {}", self.stage));
        }
        Ok(())
    }
}
