//! Background BLE session (port of Native/BLESecurity.swift + the notification
//! subset of Native/BLEController.swift).
//!
//! `droidmirror-bluetooth --notifications ADDRESS` stays connected to one
//! phone's background bridge and:
//!   stdout: one decrypted JSON message per line (`notification`, `removed`, …)
//!           plus `{"type":"_status", …}` lines for the host UI
//!   stdin:  one JSON command per line (`dismiss`, `action`, `ping`), sealed
//!           and sent only on an authenticated session.
//!
//! Handshake (unchanged from macOS): hello(macNonce[, keyId]) → challenge
//! (phoneNonce, HMAC(master,"phone"|mac|phone)) → finish(HMAC(master,"mac"|salt))
//! → sealed `ready`. Directional AES-256-GCM keys come from HKDF-SHA256 with the
//! nonces as salt; sequence numbers are strictly increasing and replay-checked.

use crate::crypto::{self, hmac};
use crate::store;
use aes_gcm::aead::{Aead, KeyInit, Payload};
use aes_gcm::{Aes256Gcm, Nonce};
use anyhow::{anyhow, bail, Context, Result};
use base64::engine::general_purpose::STANDARD as B64;
use base64::Engine;
use bluer::gatt::remote::{Characteristic, CharacteristicWriteRequest};
use bluer::gatt::WriteOp;
use bluer::{Adapter, AdapterEvent, Address, DiscoveryFilter, DiscoveryTransport};
use futures::StreamExt;
use rand::RngCore;
use serde_json::{json, Value};
use std::io::Write;
use std::time::Duration;
use tokio::io::AsyncBufReadExt;
use tokio::sync::mpsc;
use tokio::time::{sleep, timeout, Instant};
use uuid::Uuid;

const SERVICE: Uuid = Uuid::from_u128(0x7e57b000_9a6b_4c5d_8e7f_102030405060);
const ENDPOINT: Uuid = Uuid::from_u128(0x7e57b001_9a6b_4c5d_8e7f_102030405060);
const MAX_SEQUENCE: u64 = 9_007_199_254_740_990;

fn emit(value: &Value) {
    let mut out = std::io::stdout().lock();
    let _ = writeln!(out, "{value}");
    let _ = out.flush();
}

fn status(text: &str, connected: bool) {
    emit(&json!({"type": "_status", "status": text, "connected": connected}));
}

/// Public id that lets the phone pick this computer's credential.
pub fn key_id(notification: &[u8; 32]) -> [u8; 8] {
    hmac(notification, &[b"DroidMirror BLE key id v1"])[..8].try_into().unwrap()
}

pub fn presence_beacon(notification: &[u8; 32]) -> Uuid {
    let digest = hmac(notification, &[b"DroidMirror presence beacon v1"]);
    let mut b: [u8; 16] = digest[..16].try_into().unwrap();
    b[6] = (b[6] & 15) | 128;
    b[8] = (b[8] & 63) | 128;
    Uuid::from_bytes(b)
}

fn hkdf(master: &[u8; 32], salt: &[u8], info: &str) -> [u8; 32] {
    let prk = hmac(salt, &[master]);
    hmac(&prk, &[info.as_bytes(), &[1]])
}

struct Secure {
    master: [u8; 32],
    mac_nonce: [u8; 32],
    send: Option<Aes256Gcm>,
    receive: Option<Aes256Gcm>,
    sent: u64,
    received: u64,
    authenticated: bool,
}

impl Secure {
    fn new(master: [u8; 32]) -> Self {
        let mut mac_nonce = [0u8; 32];
        rand::thread_rng().fill_bytes(&mut mac_nonce);
        Secure { master, mac_nonce, send: None, receive: None, sent: 0, received: 0, authenticated: false }
    }
    fn hello(&self) -> Value {
        json!({"type": "hello", "nonce": B64.encode(self.mac_nonce), "keyId": B64.encode(key_id(&self.master))})
    }
    fn challenge(&mut self, object: &Value) -> Result<Value> {
        if self.send.is_some() {
            bail!("duplicate challenge");
        }
        let nonce = B64.decode(object["nonce"].as_str().unwrap_or("")).context("challenge nonce")?;
        let proof = B64.decode(object["proof"].as_str().unwrap_or("")).context("challenge proof")?;
        if nonce.len() != 32 || !crypto::equal(&proof, &hmac(&self.master, &[b"phone", &self.mac_nonce, &nonce])) {
            bail!("The phone failed to prove the pairing code");
        }
        let salt = [&self.mac_nonce[..], &nonce[..]].concat();
        self.send = Some(Aes256Gcm::new(&hkdf(&self.master, &salt, "DroidMirror BLE v2 mac").into()));
        self.receive = Some(Aes256Gcm::new(&hkdf(&self.master, &salt, "DroidMirror BLE v2 phone").into()));
        let proof = hmac(&self.master, &[b"mac", &salt]);
        Ok(json!({"type": "finish", "proof": B64.encode(proof)}))
    }
    fn iv(prefix: &[u8; 4], sequence: u64) -> [u8; 12] {
        let mut iv = [0u8; 12];
        iv[..4].copy_from_slice(prefix);
        iv[4..].copy_from_slice(&sequence.to_be_bytes());
        iv
    }
    fn seal(&mut self, object: &Value) -> Result<Vec<u8>> {
        let cipher = self.send.as_ref().filter(|_| self.authenticated && self.sent < MAX_SEQUENCE).ok_or_else(|| anyhow!("not authenticated"))?;
        self.sent += 1;
        let iv = Self::iv(b"DM2M", self.sent);
        let plain = serde_json::to_vec(object)?;
        let ciphertext = cipher.encrypt(Nonce::from_slice(&iv), Payload { msg: &plain, aad: &iv }).map_err(|_| anyhow!("seal failed"))?;
        let combined = [&iv[..], &ciphertext[..]].concat();
        Ok(serde_json::to_vec(&json!({"seq": self.sent, "box": B64.encode(combined)}))?)
    }
    fn open(&mut self, envelope: &Value) -> Result<Value> {
        let cipher = self.receive.as_ref().ok_or_else(|| anyhow!("no session"))?;
        let sequence = envelope["seq"].as_u64().ok_or_else(|| anyhow!("missing sequence"))?;
        if sequence <= self.received || sequence > MAX_SEQUENCE {
            bail!("replayed or out-of-order message");
        }
        let iv = Self::iv(b"DM2P", sequence);
        let data = B64.decode(envelope["box"].as_str().unwrap_or("")).context("box")?;
        if data.len() < 28 || data[..12] != iv {
            bail!("invalid envelope");
        }
        let plain = cipher.decrypt(Nonce::from_slice(&iv), Payload { msg: &data[12..], aad: &iv }).map_err(|_| anyhow!("authentication failed"))?;
        let object: Value = serde_json::from_slice(&plain)?;
        if !self.authenticated {
            if object["type"] != "ready" {
                bail!("expected ready");
            }
            self.authenticated = true;
        }
        self.received = sequence;
        Ok(object)
    }
}

impl Drop for Secure {
    fn drop(&mut self) {
        self.master.fill(0);
    }
}

#[derive(Default)]
struct Fragments {
    message: Option<u32>,
    total: usize,
    bytes: Vec<u8>,
    started: Option<Instant>,
}

impl Fragments {
    fn accept(&mut self, data: &[u8]) -> Option<Vec<u8>> {
        if data.len() <= 9 || data[0] != 0xd2 {
            return None;
        }
        let id = u32::from_be_bytes(data[1..5].try_into().unwrap());
        let offset = u16::from_be_bytes([data[5], data[6]]) as usize;
        let length = u16::from_be_bytes([data[7], data[8]]) as usize;
        if length == 0 || length > 8192 {
            return None;
        }
        if offset == 0 {
            self.message = Some(id);
            self.total = length;
            self.bytes.clear();
            self.started = Some(Instant::now());
        }
        let fresh = self.started.is_some_and(|s| s.elapsed() < Duration::from_secs(15));
        if self.message != Some(id) || length != self.total || offset != self.bytes.len() || !fresh || self.bytes.len() + data.len() - 9 > self.total {
            self.message = None;
            self.bytes.clear();
            return None;
        }
        self.bytes.extend_from_slice(&data[9..]);
        if self.bytes.len() == self.total {
            self.message = None;
            return Some(std::mem::take(&mut self.bytes));
        }
        None
    }

    fn split(data: &[u8], id: u32, maximum: usize) -> Vec<Vec<u8>> {
        let capacity = maximum.min(512) - 9;
        data.chunks(capacity)
            .enumerate()
            .map(|(index, chunk)| {
                let offset = index * capacity;
                let mut frame = vec![0xd2];
                frame.extend_from_slice(&id.to_be_bytes());
                frame.extend_from_slice(&(offset as u16).to_be_bytes());
                frame.extend_from_slice(&(data.len() as u16).to_be_bytes());
                frame.extend_from_slice(chunk);
                frame
            })
            .collect()
    }
}

struct Link {
    endpoint: Characteristic,
    maximum: usize,
    next_id: u32,
}

impl Link {
    async fn send(&mut self, data: &[u8]) -> Result<()> {
        if data.is_empty() || data.len() > 8192 {
            bail!("message too large");
        }
        self.next_id = self.next_id.wrapping_add(1);
        let request = CharacteristicWriteRequest { op_type: WriteOp::Request, ..Default::default() };
        for frame in Fragments::split(data, self.next_id, self.maximum) {
            timeout(Duration::from_secs(10), self.endpoint.write_ext(&frame, &request))
                .await
                .map_err(|_| anyhow!("BLE write timed out"))??;
        }
        Ok(())
    }
}

/// Every background endpoint on the phone. More than one DroidMirror build can be
/// installed side by side, each registering the same service; only the one that
/// trusts this computer completes the handshake (same approach as macOS).
async fn find_endpoints(adapter: &Adapter, identity: Address, pairing: &[u8; 32]) -> Result<(Address, Vec<Characteristic>)> {
    let notification = crypto::notification_pairing_key(pairing);
    let discovery = Uuid::from_bytes(crypto::discovery_uuid(&notification));
    let filter = DiscoveryFilter {
        uuids: [discovery].into_iter().collect(),
        transport: DiscoveryTransport::Le,
        ..Default::default()
    };
    let _ = adapter.set_discovery_filter(filter).await;
    let mut scan = Box::pin(adapter.discover_devices().await?);
    let deadline = Instant::now() + Duration::from_secs(30);
    let mut candidates = vec![identity];
    if let Some(remembered) = store::remembered_le_peer(pairing) {
        candidates.push(remembered);
    }
    loop {
        while let Ok(Some(event)) = timeout(Duration::from_millis(200), scan.next()).await {
            if let AdapterEvent::DeviceAdded(address) = event {
                if let Ok(device) = adapter.device(address) {
                    if device.uuids().await.ok().flatten().unwrap_or_default().contains(&discovery) && !candidates.contains(&address) {
                        candidates.push(address);
                    }
                }
            }
        }
        for &address in &candidates {
            let Ok(device) = adapter.device(address) else { continue };
            let random = matches!(device.address_type().await, Ok(bluer::AddressType::LeRandom));
            let connected = device.is_connected().await.unwrap_or(false);
            // Same audio-profile caution as the mirror helper: only LE-only
            // identities are connected; the dual-mode identity is used when its
            // GATT services are already resolved.
            if !connected {
                if !random {
                    continue;
                }
                if timeout(Duration::from_secs(5), device.connect()).await.map(|r| r.is_err()).unwrap_or(true) {
                    continue;
                }
            }
            let resolved = Instant::now() + Duration::from_secs(5);
            while !device.is_services_resolved().await.unwrap_or(false) && Instant::now() < resolved {
                sleep(Duration::from_millis(100)).await;
            }
            let mut endpoints = Vec::new();
            for service in device.services().await.unwrap_or_default() {
                if service.uuid().await.ok() != Some(SERVICE) {
                    continue;
                }
                for characteristic in service.characteristics().await.unwrap_or_default() {
                    if characteristic.uuid().await.ok() == Some(ENDPOINT) {
                        endpoints.push(characteristic);
                    }
                }
            }
            if !endpoints.is_empty() {
                return Ok((address, endpoints));
            }
        }
        if Instant::now() >= deadline {
            bail!("The phone's background bridge was not found nearby");
        }
    }
}

type Values = std::pin::Pin<Box<dyn futures::Stream<Item = Vec<u8>> + Send>>;

/// Subscribes and completes the mutual handshake on one endpoint.
async fn authenticate(endpoint: Characteristic, pairing: &[u8; 32]) -> Result<(Values, Link, Secure, Fragments)> {
    let mut values: Values = Box::pin(endpoint.notify().await.context("Could not subscribe to the phone's notifications")?);
    let maximum = (endpoint.mtu().await.unwrap_or(23) as usize).saturating_sub(3).clamp(20, 512);
    let mut link = Link { endpoint, maximum, next_id: rand::random() };
    let mut secure = Secure::new(crypto::notification_pairing_key(pairing));
    let mut fragments = Fragments::default();
    link.send(&serde_json::to_vec(&secure.hello())?).await?;
    let deadline = Instant::now() + Duration::from_secs(8);
    while !secure.authenticated {
        let value = timeout(deadline.saturating_duration_since(Instant::now()), values.next())
            .await
            .map_err(|_| anyhow!("Authentication timed out"))?
            .ok_or_else(|| anyhow!("The phone closed the background connection"))?;
        let Some(message) = fragments.accept(&value) else { continue };
        let object: Value = serde_json::from_slice(&message).context("invalid message")?;
        if object["type"] == "challenge" {
            let finish = secure.challenge(&object)?;
            link.send(&serde_json::to_vec(&finish)?).await?;
        } else {
            let plain = secure.open(&object)?;
            if plain["type"] != "ready" {
                bail!("expected ready");
            }
        }
    }
    Ok((values, link, secure, fragments))
}

async fn session(adapter: &Adapter, identity: Address, pairing: [u8; 32], commands: &mut mpsc::UnboundedReceiver<Value>) -> Result<()> {
    status("Looking for the phone's background bridge", false);
    let (peer, endpoints) = find_endpoints(adapter, identity, &pairing).await?;
    status("Authenticating", false);
    let mut last_error = anyhow!("No background endpoint");
    let mut established = None;
    for endpoint in endpoints {
        match authenticate(endpoint, &pairing).await {
            Ok(result) => {
                established = Some(result);
                break;
            }
            Err(error) => {
                eprintln!("Background endpoint rejected this computer: {error:#}");
                last_error = error;
            }
        }
    }
    let Some((mut values, mut link, mut secure, mut fragments)) = established else {
        // Android only sends Service Changed to bonded clients, so after the
        // companion re-registers its service an unbonded LE link can keep a
        // stale attribute table. Drop that LE-only link so the next attempt
        // rediscovers every service (never the dual-mode identity).
        if let Ok(device) = adapter.device(peer) {
            if matches!(device.address_type().await, Ok(bluer::AddressType::LeRandom)) {
                eprintln!("Refreshing the phone's GATT services before retrying");
                let _ = device.disconnect().await;
            }
        }
        return Err(last_error.context("Check that this computer is trusted on the phone and its pairing code is current"));
    };
    store::remember_le_peer(&pairing, peer);
    status("Connected", true);
    let handshake = Instant::now();
    let mut ping = tokio::time::interval(Duration::from_secs(10));
    let mut last_pong = Instant::now();
    loop {
        tokio::select! {
            value = values.next() => {
                let Some(value) = value else { bail!("The phone closed the background connection") };
                let Some(message) = fragments.accept(&value) else { continue };
                let object: Value = serde_json::from_slice(&message).context("invalid message")?;
                if object["type"] == "challenge" {
                    let finish = secure.challenge(&object)?;
                    link.send(&serde_json::to_vec(&finish)?).await?;
                    continue;
                }
                let plain = secure.open(&object)?;
                match plain["type"].as_str() {
                    Some("pong") => last_pong = Instant::now(),
                    _ => emit(&plain),
                }
            }
            command = commands.recv() => {
                let Some(command) = command else { return Ok(()) };
                if secure.authenticated {
                    let sealed = secure.seal(&command)?;
                    link.send(&sealed).await?;
                }
            }
            _ = ping.tick() => {
                if !secure.authenticated {
                    if Instant::now() > handshake {
                        bail!("Authentication timed out. Check the pairing code for this computer.");
                    }
                    continue;
                }
                if last_pong.elapsed() > Duration::from_secs(25) {
                    bail!("The phone stopped responding");
                }
                let request = Uuid::new_v4().to_string();
                let sealed = secure.seal(&json!({"type": "ping", "request": request}))?;
                link.send(&sealed).await?;
            }
        }
    }
}

pub async fn run(identity: Address, pairing: [u8; 32]) -> Result<()> {
    let session_bus = bluer::Session::new().await?;
    let adapter = session_bus.default_adapter().await?;
    // Presence beacon for the phone's left-behind detection (same UUID as macOS).
    let notification = crypto::notification_pairing_key(&pairing);
    let beacon = presence_beacon(&notification);
    let _advertisement = match adapter
        .advertise(bluer::adv::Advertisement {
            advertisement_type: bluer::adv::Type::Broadcast,
            min_interval: Some(Duration::from_millis(500)),
            max_interval: Some(Duration::from_millis(1000)),
            service_uuids: [beacon].into_iter().collect(),
            ..Default::default()
        })
        .await
    {
        Ok(handle) => Some(handle),
        Err(error) => {
            eprintln!("Presence beacon unavailable: {error}");
            None
        }
    };
    let (tx, mut rx) = mpsc::unbounded_channel::<Value>();
    tokio::spawn(async move {
        let mut lines = tokio::io::BufReader::new(tokio::io::stdin()).lines();
        while let Ok(Some(line)) = lines.next_line().await {
            if let Ok(value) = serde_json::from_str::<Value>(&line) {
                // Every command is sealed into this computer's authenticated session;
                // the phone validates each one. Handshake messages are never relayed.
                let allowed = value["type"].as_str().is_some_and(|t| !matches!(t, "hello" | "finish" | "challenge" | "ready"));
                if allowed && tx.send(value).is_err() {
                    break;
                }
            }
        }
        std::process::exit(0); // host closed stdin
    });
    let mut backoff = 2;
    loop {
        match session(&adapter, identity, pairing, &mut rx).await {
            Ok(()) => return Ok(()),
            Err(error) => {
                status(&format!("{error:#}"), false);
                eprintln!("Background session ended: {error:#}");
            }
        }
        sleep(Duration::from_secs(backoff)).await;
        backoff = (backoff * 2).min(60);
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn fragments_round_trip() {
        let data: Vec<u8> = (0..1500u32).map(|i| i as u8).collect();
        let frames = Fragments::split(&data, 7, 185);
        let mut assembler = Fragments::default();
        let mut out = None;
        for frame in &frames {
            assert!(frame.len() <= 185);
            out = assembler.accept(frame).or(out);
        }
        assert_eq!(out.unwrap(), data);
    }

    #[test]
    fn handshake_and_envelopes_interoperate() {
        // Simulate the phone side with the same derivations as BleSecurity.kt.
        let master = [5u8; 32];
        let mut mac = Secure::new(master);
        let phone_nonce = [9u8; 32];
        let proof = hmac(&master, &[b"phone", &mac.mac_nonce, &phone_nonce]);
        let finish = mac.challenge(&json!({"type": "challenge", "nonce": B64.encode(phone_nonce), "proof": B64.encode(proof)})).unwrap();
        let salt = [&mac.mac_nonce[..], &phone_nonce[..]].concat();
        assert_eq!(B64.decode(finish["proof"].as_str().unwrap()).unwrap(), hmac(&master, &[b"mac", &salt]));
        // Phone seals "ready" with its outgoing key.
        let phone_key = Aes256Gcm::new(&hkdf(&master, &salt, "DroidMirror BLE v2 phone").into());
        let iv = Secure::iv(b"DM2P", 1);
        let boxed = phone_key.encrypt(Nonce::from_slice(&iv), Payload { msg: br#"{"type":"ready"}"#, aad: &iv }).unwrap();
        let envelope = json!({"seq": 1, "box": B64.encode([&iv[..], &boxed[..]].concat())});
        assert_eq!(mac.open(&envelope).unwrap()["type"], "ready");
        assert!(mac.open(&envelope).is_err(), "replay rejected");
        assert!(mac.seal(&json!({"type": "subscribe"})).is_ok());
    }
}
