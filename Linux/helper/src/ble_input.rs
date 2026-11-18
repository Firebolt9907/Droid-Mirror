//! BlueZ port of Native/BleInputTransport.m: the per-session authenticated BLE
//! side channel that carries all input, acknowledgements, control replies and
//! phone events while Classic L2CAP (or an authenticated direct-IP lane) carries
//! video.
//!
//! Security properties preserved from the macOS implementation:
//! * session keys derive from the private pairing root and the phone's nonce;
//! * the phone must prove the session key before any input is written;
//! * every record is encrypted + authenticated under a strictly increasing
//!   directional sequence; only the exact last ciphertext may be re-acknowledged;
//! * service-change recovery is bounded (4 s), requires the *same* session
//!   nonce, re-proves the key and authenticates the phone's resume sequence
//!   before any ciphertext is retransmitted. Recovery never resets sequences.

use crate::crypto::{self, Keys};
use crate::queue::{monotonic_ms, monotonic_secs, InputQueue};
use crate::store;
use anyhow::{anyhow, bail, Context, Result};
use bluer::gatt::remote::{Characteristic, CharacteristicWriteRequest};
use bluer::gatt::{CharacteristicWriter, WriteOp};
use bluer::{Adapter, AdapterEvent, Address, Device, DiscoveryFilter, DiscoveryTransport};
use futures::{Stream, StreamExt};
use rand::RngCore;
use std::collections::HashSet;
use std::pin::Pin;
use std::sync::atomic::{AtomicBool, AtomicI8, Ordering};
use std::sync::{Arc, Mutex};
use std::time::Duration;
use tokio::sync::mpsc;
use tokio::time::{sleep, timeout, Instant};
use uuid::Uuid;

pub const INPUT_SERVICE: Uuid = Uuid::from_u128(0xc356a44e_6f2b_4da9_85e5_397991b8a610);
const INPUT: Uuid = Uuid::from_u128(0xc356a44e_6f2b_4da9_85e5_397991b8a611);
const PROOF: Uuid = Uuid::from_u128(0xc356a44e_6f2b_4da9_85e5_397991b8a612);
const RETURN: Uuid = Uuid::from_u128(0xc356a44e_6f2b_4da9_85e5_397991b8a613);
const NONCE: Uuid = Uuid::from_u128(0xc356a44e_6f2b_4da9_85e5_397991b8a614);
const CLOCK: Uuid = Uuid::from_u128(0xc356a44e_6f2b_4da9_85e5_397991b8a615);
const RESUME: Uuid = Uuid::from_u128(0xc356a44e_6f2b_4da9_85e5_397991b8a616);
const REPLAY: Uuid = Uuid::from_u128(0xc356a44e_6f2b_4da9_85e5_397991b8a617);
const UNLOCK_DECISION: Uuid = Uuid::from_u128(0xc356a44e_6f2b_4da9_85e5_397991b8a618);
pub const NOTIFICATION_SERVICE: Uuid = Uuid::from_u128(0x7e57b000_9a6b_4c5d_8e7f_102030405060);

pub enum Command {
    Send(Vec<u8>),
    AcknowledgeVideo(u64),
    RequestBluetoothVideo(u64, [u8; 32]),
    UnlockDecision(bool),
}

pub enum Event {
    Ready,
    Received(Vec<u8>),
    Failed(String),
}

#[derive(Default)]
pub struct Status {
    pub ready: AtomicBool,
    pub recovering: AtomicBool,
    pub proof_rejected: AtomicBool,
    /// -1 deferred until the host answers; 0 manual unlock; 1 saved PIN allowed.
    pub unlock_decision: AtomicI8,
    pub startup_pending: AtomicBool,
    pub stage: Mutex<String>,
}

impl Status {
    pub fn awaiting_unlock_decision(&self) -> bool {
        self.startup_pending.load(Ordering::SeqCst) && self.unlock_decision.load(Ordering::SeqCst) < 0
    }
    pub fn stage(&self) -> String {
        self.stage.lock().unwrap().clone()
    }
}

pub struct Handle {
    pub status: Arc<Status>,
    commands: mpsc::UnboundedSender<Command>,
    task: tokio::task::JoinHandle<()>,
}

impl Handle {
    pub fn usable(&self) -> bool {
        self.status.ready.load(Ordering::SeqCst) || self.status.recovering.load(Ordering::SeqCst)
    }
    pub fn send(&self, command: Command) -> bool {
        self.usable() && self.commands.send(command).is_ok()
    }
    pub fn resolve_unlock(&self, allowed: bool) {
        let _ = self.commands.send(Command::UnlockDecision(allowed));
    }
    pub fn close(&self) {
        self.status.ready.store(false, Ordering::SeqCst);
        self.task.abort();
    }
}

pub fn start(adapter: Adapter, classic: Address, key: [u8; 32], unlock: i8, events: mpsc::UnboundedSender<Event>) -> Handle {
    let status = Arc::new(Status::default());
    status.unlock_decision.store(unlock, Ordering::SeqCst);
    status.startup_pending.store(true, Ordering::SeqCst);
    let (commands, receiver) = mpsc::unbounded_channel();
    let task_status = status.clone();
    let task = tokio::spawn(async move {
        let failure_events = events.clone();
        let mut transport = Transport::new(adapter, classic, key, task_status, events, receiver);
        if let Err(error) = transport.run().await {
            eprintln!(
                "BLE failure: {error:#} (ready={} recovering={})",
                transport.status.ready.load(Ordering::SeqCst),
                transport.status.recovering.load(Ordering::SeqCst)
            );
            transport.status.ready.store(false, Ordering::SeqCst);
            let _ = failure_events.send(Event::Failed(format!("{error:#}")));
        }
    });
    Handle { status, commands, task }
}

struct Chars {
    input: Characteristic,
    proof: Characteristic,
    returning: Characteristic,
    nonce: Characteristic,
    clock: Characteristic,
    resume: Option<Characteristic>,
    replay: Option<Characteristic>,
    input_streaming: bool,
    input_reliable: bool,
    return_notify: bool,
    return_indicate: bool,
}

enum Attempt {
    /// The phone failed to prove the pairing key, or offered an incompatible service.
    Reject,
    /// Slow radio or a service that is not yet published; retry soon.
    Defer,
}

/// Only ever accessed through `&mut Transport`, so exposing it as `Sync`
/// is sound (the same reasoning as the `sync_wrapper` crate).
struct Values(Pin<Box<dyn Stream<Item = Vec<u8>> + Send>>);
unsafe impl Sync for Values {}

struct Transport {
    adapter: Adapter,
    classic: Address,
    pairing: [u8; 32],
    status: Arc<Status>,
    events: mpsc::UnboundedSender<Event>,
    commands: mpsc::UnboundedReceiver<Command>,
    queue: InputQueue,
    device: Option<Device>,
    chars: Option<Chars>,
    writer: Option<CharacteristicWriter>,
    values: Option<Values>,
    keys: Keys,
    return_keys: Keys,
    session_nonce: Option<Vec<u8>>,
    challenge: [u8; 16],
    sequence: u64,
    receive_sequence: u64,
    in_flight: Option<Vec<u8>>,
    retry_input: bool,
    last_return_packet: Option<Vec<u8>>,
    pending_return_ack: Option<u64>,
    input_turn: bool,
    next_read: f64,
    progress: f64,
    reliable_after_recovery: bool,
    credit_wait_since: f64,
    rejected: HashSet<Address>,
    deferred: Option<(Address, f64)>,
}

fn stage(status: &Status, text: &str) {
    *status.stage.lock().unwrap() = text.to_string();
    eprintln!("BLE setup: {text}");
}

fn is_gone(error: &bluer::Error) -> bool {
    matches!(
        error.kind,
        bluer::ErrorKind::NotFound | bluer::ErrorKind::DoesNotExist | bluer::ErrorKind::ServicesUnresolved
    ) || error.message.contains("UnknownObject")
        || error.message.contains("doesn't exist")
}

impl Transport {
    fn new(
        adapter: Adapter,
        classic: Address,
        pairing: [u8; 32],
        status: Arc<Status>,
        events: mpsc::UnboundedSender<Event>,
        commands: mpsc::UnboundedReceiver<Command>,
    ) -> Self {
        Transport {
            adapter,
            classic,
            pairing,
            status,
            events,
            commands,
            queue: InputQueue::new(),
            device: None,
            chars: None,
            writer: None,
            values: None,
            keys: Keys::default(),
            return_keys: Keys::default(),
            session_nonce: None,
            challenge: [0; 16],
            sequence: 1,
            receive_sequence: 1,
            in_flight: None,
            retry_input: false,
            last_return_packet: None,
            pending_return_ack: None,
            input_turn: false,
            next_read: 0.0,
            progress: monotonic_secs(),
            reliable_after_recovery: false,
            credit_wait_since: 0.0,
            rejected: HashSet::new(),
            deferred: None,
        }
    }

    fn discovery_uuid(&self) -> Uuid {
        let notification = crypto::notification_pairing_key(&self.pairing);
        Uuid::from_bytes(crypto::discovery_uuid(&notification))
    }

    async fn run(&mut self) -> Result<()> {
        self.connect().await?;
        self.serve().await
    }

    // ---- Candidate selection ------------------------------------------------

    async fn candidates(&self, discovered: &[Address]) -> Vec<Address> {
        let mut out = vec![self.classic];
        if let Some(remembered) = store::remembered_le_peer(&self.pairing) {
            out.push(remembered);
        }
        out.extend_from_slice(discovered);
        // Another process can already own an LE link to the phone with the
        // input or notification service resolved; it may never advertise again.
        if let Ok(addresses) = self.adapter.device_addresses().await {
            for address in addresses {
                if let Ok(device) = self.adapter.device(address) {
                    if device.is_connected().await.unwrap_or(false) {
                        let uuids = device.uuids().await.ok().flatten().unwrap_or_default();
                        if uuids.contains(&INPUT_SERVICE) || uuids.contains(&self.discovery_uuid()) {
                            out.push(address);
                        }
                    }
                }
            }
        }
        let mut seen = HashSet::new();
        out.retain(|a| seen.insert(*a) && !self.rejected.contains(a));
        out
    }

    async fn connect(&mut self) -> Result<()> {
        stage(&self.status, "looking for the paired phone's BLE service");
        let discovery = self.discovery_uuid();
        let filter = DiscoveryFilter {
            uuids: [discovery].into_iter().collect(),
            transport: DiscoveryTransport::Le,
            duplicate_data: false,
            ..Default::default()
        };
        if let Err(error) = self.adapter.set_discovery_filter(filter).await {
            eprintln!("BLE discovery filter unavailable: {error}");
        }
        let mut scan = match self.adapter.discover_devices().await {
            Ok(stream) => Some(Box::pin(stream)),
            Err(error) => {
                eprintln!("BLE discovery unavailable: {error}; using known phone links only");
                None
            }
        };
        let mut discovered: Vec<Address> = Vec::new();
        loop {
            // Collect advertisements carrying this pairing's discovery UUID.
            if let Some(stream) = scan.as_mut() {
                while let Ok(Some(event)) = timeout(Duration::from_millis(1), stream.next()).await {
                    if let AdapterEvent::DeviceAdded(address) = event {
                        if let Ok(device) = self.adapter.device(address) {
                            let uuids = device.uuids().await.ok().flatten().unwrap_or_default();
                            if uuids.contains(&discovery) && !discovered.contains(&address) {
                                eprintln!("BLE candidate advertised the pairing discovery UUID: {address}");
                                discovered.push(address);
                            }
                        }
                    }
                }
            }
            let now = monotonic_secs();
            for address in self.candidates(&discovered).await {
                if let Some((deferred, until)) = self.deferred {
                    if deferred == address && now < until {
                        continue;
                    }
                }
                eprintln!("BLE candidate: {address}");
                match self.attempt(address).await {
                    Ok(()) => {
                        drop(scan);
                        store::remember_le_peer(&self.pairing, address);
                        return Ok(());
                    }
                    Err(Attempt::Reject) => {
                        stage(&self.status, "rejecting a BLE candidate with incompatible service or pairing proof");
                        self.rejected.insert(address);
                    }
                    Err(Attempt::Defer) => {
                        self.deferred = Some((address, monotonic_secs() + 2.0));
                    }
                }
                self.reset_attributes();
            }
            stage(&self.status, "looking for the paired phone's BLE service");
            sleep(Duration::from_millis(250)).await;
        }
    }

    fn is_classic(&self, device: &Device) -> bool {
        device.address() == self.classic
    }

    fn reset_attributes(&mut self) {
        self.chars = None;
        self.writer = None;
        self.values = None;
    }

    async fn ensure_connected(&self, device: &Device) -> Result<(), Attempt> {
        if device.is_connected().await.unwrap_or(false) && device.is_services_resolved().await.unwrap_or(false) {
            return Ok(());
        }
        // Never ask BlueZ to Connect() a dual-mode (BR/EDR-capable) device: with
        // the Classic video link up, BlueZ would connect its BR/EDR profiles
        // (A2DP/HFP) and could start routing the phone's audio to this computer.
        // Such a device is used only once its GATT services are already
        // resolved (over LE or BR/EDR). LE-only identities (the phone's
        // advertising address) are safe to connect: that creates an LE link only.
        let le_only = matches!(device.address_type().await, Ok(bluer::AddressType::LeRandom))
            || device.class().await.ok().flatten().is_none() && !self.is_classic(device);
        if !le_only {
            let deadline = Instant::now() + Duration::from_millis(1500);
            while Instant::now() < deadline {
                if device.is_connected().await.unwrap_or(false) && device.is_services_resolved().await.unwrap_or(false) {
                    return Ok(());
                }
                sleep(Duration::from_millis(100)).await;
            }
            return Err(Attempt::Defer);
        }
        stage(&self.status, "connecting to a BLE service candidate");
        if !device.is_connected().await.unwrap_or(false) {
            match timeout(Duration::from_secs(4), device.connect()).await {
                Ok(Ok(())) => {}
                Ok(Err(error)) => {
                    eprintln!("BLE connect failed: {error}");
                    return Err(Attempt::Defer);
                }
                Err(_) => {
                    eprintln!("BLE candidate connection stalled; checking other phone links");
                    return Err(Attempt::Defer);
                }
            }
        }
        let deadline = Instant::now() + Duration::from_secs(4);
        while !device.is_services_resolved().await.unwrap_or(false) {
            if Instant::now() >= deadline {
                return Err(Attempt::Defer);
            }
            sleep(Duration::from_millis(100)).await;
        }
        Ok(())
    }

    async fn find_chars(&self, device: &Device, deadline: Instant) -> Result<Chars, Attempt> {
        stage(&self.status, "discovering BLE services");
        loop {
            if let Ok(services) = device.services().await {
                for service in services {
                    if service.uuid().await.ok() != Some(INPUT_SERVICE) {
                        continue;
                    }
                    stage(&self.status, "discovering BLE characteristics");
                    let Ok(characteristics) = service.characteristics().await else { continue };
                    let mut found: [Option<Characteristic>; 8] = Default::default();
                    let mut unlock = false;
                    for c in characteristics {
                        let Ok(uuid) = c.uuid().await else { continue };
                        let slot = match uuid {
                            u if u == INPUT => 0,
                            u if u == PROOF => 1,
                            u if u == RETURN => 2,
                            u if u == NONCE => 3,
                            u if u == CLOCK => 4,
                            u if u == RESUME => 5,
                            u if u == REPLAY => 6,
                            u if u == UNLOCK_DECISION => {
                                unlock = true;
                                7
                            }
                            _ => continue,
                        };
                        found[slot] = Some(c);
                    }
                    let [input, proof, returning, nonce, clock, resume, replay, _] = found;
                    let (Some(input), Some(proof), Some(returning), Some(nonce), Some(clock)) =
                        (input, proof, returning, nonce, clock)
                    else {
                        continue;
                    };
                    let input_flags = input.flags().await.map_err(|_| Attempt::Defer)?;
                    let proof_flags = proof.flags().await.map_err(|_| Attempt::Defer)?;
                    let return_flags = returning.flags().await.map_err(|_| Attempt::Defer)?;
                    let clock_flags = clock.flags().await.map_err(|_| Attempt::Defer)?;
                    if !clock_flags.read || !return_flags.read || !proof_flags.read || !proof_flags.write || !input_flags.write {
                        continue;
                    }
                    if !unlock {
                        // Fails closed exactly like the Mac: an old companion cannot
                        // honour the host's manual-unlock decision.
                        let _ = self.events.send(Event::Failed(
                            "Update the Android companion before mirroring: safe manual unlock startup is unavailable.".into(),
                        ));
                        return Err(Attempt::Reject);
                    }
                    return Ok(Chars {
                        input,
                        proof,
                        returning,
                        nonce,
                        clock,
                        resume,
                        replay,
                        input_streaming: input_flags.write_without_response,
                        input_reliable: input_flags.write,
                        return_notify: return_flags.notify,
                        return_indicate: return_flags.indicate,
                    });
                }
            }
            // Android adds this GATT service asynchronously after accepting Classic.
            if Instant::now() >= deadline {
                return Err(Attempt::Defer);
            }
            stage(&self.status, "waiting for Android's BLE input service to become available");
            sleep(Duration::from_millis(250)).await;
        }
    }

    /// Reads the nonce, derives keys and verifies the phone's pairing proof.
    async fn prove(&mut self, chars: &Chars, recovering: bool) -> Result<(), Attempt> {
        stage(&self.status, "reading the BLE session nonce");
        let nonce = chars.nonce.read().await.map_err(|error| {
            eprintln!("BLE nonce read not ready: {error}");
            Attempt::Defer
        })?;
        if nonce.len() != 32 {
            return Err(if recovering { Attempt::Defer } else { Attempt::Reject });
        }
        if recovering && self.session_nonce.as_deref() != Some(&nonce[..]) {
            let _ = self.events.send(Event::Failed("Android replaced the BLE session; reconnect the mirror.".into()));
            return Err(Attempt::Reject);
        }
        let mut session = crypto::session_key(&self.pairing, &nonce);
        self.keys = crypto::input_keys(&session);
        self.return_keys = crypto::output_keys(&session);
        session.fill(0);
        self.session_nonce = Some(nonce);
        rand::thread_rng().fill_bytes(&mut self.challenge);
        stage(&self.status, "writing the BLE authentication challenge");
        let request = CharacteristicWriteRequest { op_type: WriteOp::Request, ..Default::default() };
        if chars.proof.write_ext(&self.challenge, &request).await.is_err() {
            return Err(Attempt::Reject);
        }
        stage(&self.status, "reading the BLE pairing proof");
        let proof = chars.proof.read().await.map_err(|_| Attempt::Reject)?;
        let expected = crypto::input_proof(&self.keys, &self.challenge);
        if !crypto::equal(&proof, &expected) {
            if !recovering {
                self.status.proof_rejected.store(true, Ordering::SeqCst);
            }
            return Err(Attempt::Reject);
        }
        self.status.proof_rejected.store(false, Ordering::SeqCst);
        Ok(())
    }

    async fn synchronize_clock(&mut self, chars: &Chars) -> Result<()> {
        stage(&self.status, "reading the authenticated phone clock");
        let value = chars.clock.read().await.context("BLE clock synchronization failed. Update the Android companion.")?;
        if value.len() != 40 {
            bail!("BLE clock synchronization failed. Update the Android companion.");
        }
        if !crypto::equal(&crypto::clock_proof(&self.keys, &value[..8]), &value[8..]) {
            bail!("Invalid authenticated phone clock.");
        }
        let phone = u64::from_be_bytes(value[..8].try_into().unwrap());
        self.queue.synchronize_phone_clock(phone, monotonic_ms());
        Ok(())
    }

    async fn subscribe(&mut self, chars: &Chars) -> Result<()> {
        if chars.return_notify || chars.return_indicate {
            stage(&self.status, "subscribing authenticated BLE returns");
            let stream = chars.returning.notify().await.context("BLE return subscription failed.")?;
            self.values = Some(Values(Box::pin(stream)));
        }
        self.writer = None;
        if chars.input_streaming && !self.reliable_after_recovery {
            match chars.input.write_io().await {
                Ok(writer) => self.writer = Some(writer),
                Err(error) => eprintln!("BLE streaming writes unavailable ({error}); using acknowledged writes"),
            }
        }
        Ok(())
    }

    async fn attempt(&mut self, address: Address) -> Result<(), Attempt> {
        let device = self.adapter.device(address).map_err(|_| Attempt::Defer)?;
        self.ensure_connected(&device).await?;
        let chars = self.find_chars(&device, Instant::now() + Duration::from_secs(4)).await?;
        self.prove(&chars, false).await?;
        self.synchronize_clock(&chars).await.map_err(|error| {
            let _ = self.events.send(Event::Failed(format!("{error:#}")));
            Attempt::Reject
        })?;
        self.subscribe(&chars).await.map_err(|error| {
            let _ = self.events.send(Event::Failed(format!("{error:#}")));
            Attempt::Reject
        })?;
        let mtu = chars.input.mtu().await.unwrap_or(23);
        eprintln!(
            "BLE input capacity: att-mtu={mtu} streaming writes={}",
            if self.writer.is_some() { "available" } else { "unavailable" }
        );
        if mtu <= 27 && self.writer.is_none() {
            // ATT long writes still work with BlueZ, but match the Mac's guard.
            eprintln!("BLE MTU is small; relying on prepared writes for authenticated commands");
        }
        self.device = Some(device);
        self.chars = Some(chars);
        self.finish_authentication();
        Ok(())
    }

    fn finish_authentication(&mut self) {
        let returns = match &self.chars {
            Some(c) if c.return_notify => "authenticated BLE ready (acknowledged returns)",
            Some(c) if c.return_indicate => "authenticated BLE ready (indicated returns)",
            _ => "authenticated BLE ready",
        };
        stage(&self.status, returns);
        self.status.ready.store(true, Ordering::SeqCst);
        self.status.recovering.store(false, Ordering::SeqCst);
        self.progress = monotonic_secs();
        self.next_read = self.progress + 0.5;
        let _ = self.events.send(Event::Ready);
    }

    // ---- Recovery -------------------------------------------------------------

    /// Bounded rediscovery and reauthentication after Android replaced the
    /// GATT attribute table under an active session (Service Changed). The
    /// session nonce must be unchanged and the phone must authenticate its
    /// next expected sequence before an uncertain ciphertext is retransmitted.
    async fn recover(&mut self, reason: &str) -> Result<()> {
        stage(&self.status, reason);
        self.status.ready.store(false, Ordering::SeqCst);
        self.status.recovering.store(true, Ordering::SeqCst);
        let needs_return = self.values.is_some() || self.chars.as_ref().is_some_and(|c| !c.return_notify && !c.return_indicate);
        self.reset_attributes();
        let deadline = Instant::now() + Duration::from_secs(4);
        let device = self.device.clone().ok_or_else(|| anyhow!("BLE input disconnected; ending the mirror session."))?;
        loop {
            if Instant::now() >= deadline {
                bail!("BLE service recovery timed out; reconnect the mirror.");
            }
            if !device.is_connected().await.unwrap_or(false) {
                bail!("BLE input disconnected; ending the mirror session.");
            }
            let chars = match self.find_chars(&device, deadline).await {
                Ok(chars) => chars,
                Err(_) => continue,
            };
            match self.prove(&chars, true).await {
                Ok(()) => {}
                Err(Attempt::Defer) => {
                    sleep(Duration::from_millis(100)).await;
                    continue;
                }
                Err(Attempt::Reject) => bail!("BLE service recovery authentication failed; reconnect the mirror."),
            }
            let (Some(resume), Some(replay)) = (chars.resume.clone(), chars.replay.clone()) else {
                bail!("BLE service recovery requires an updated Android companion.");
            };
            stage(&self.status, "reading authenticated BLE recovery state");
            let value = resume.read().await.context("BLE recovery state unavailable; update the companion.")?;
            if value.len() != 40 {
                bail!("BLE recovery state unavailable; update the companion.");
            }
            let expected = crypto::resume_proof(&self.keys, &self.challenge, &value[..8]);
            let next = u64::from_be_bytes(value[..8].try_into().unwrap());
            if !crypto::equal(&expected, &value[8..])
                || next == 0
                || (next != self.sequence && (self.in_flight.is_none() || next != self.sequence - 1))
            {
                bail!("Invalid authenticated BLE recovery sequence.");
            }
            self.retry_input = next != self.sequence;
            if !self.retry_input {
                self.in_flight = None;
            }
            if needs_return {
                let packet = replay.read().await.context("BLE recovery return unavailable.")?;
                if !packet.is_empty() {
                    if packet.len() <= 24 || packet.len() > 512 {
                        bail!("BLE recovery return unavailable.");
                    }
                    let sequence = u64::from_be_bytes(packet[..8].try_into().unwrap());
                    if sequence != self.receive_sequence && sequence != self.receive_sequence - 1 {
                        bail!("Invalid BLE recovery return sequence.");
                    }
                    let plain = crypto::open(&self.return_keys, sequence, &packet)
                        .ok_or_else(|| anyhow!("Invalid BLE recovery return sequence."))?;
                    if sequence == self.receive_sequence {
                        self.receive_sequence += 1;
                        let _ = self.events.send(Event::Received(plain));
                    }
                }
            }
            self.synchronize_clock(&chars).await?;
            self.subscribe(&chars).await?;
            self.chars = Some(chars);
            self.finish_authentication();
            return Ok(());
        }
    }

    // ---- Steady state -----------------------------------------------------------

    async fn serve(&mut self) -> Result<()> {
        let mut tick = tokio::time::interval(Duration::from_millis(10));
        tick.set_missed_tick_behavior(tokio::time::MissedTickBehavior::Skip);
        let mut last_link_check = monotonic_secs();
        loop {
            let value = async {
                match self.values.as_mut() {
                    Some(values) => values.0.next().await,
                    None => std::future::pending().await,
                }
            };
            tokio::select! {
                command = self.commands.recv() => {
                    let Some(command) = command else { return Ok(()) };
                    self.command(command)?;
                }
                value = value => {
                    match value {
                        Some(packet) => self.returned(packet)?,
                        None => {
                            self.recover("recovering the active BLE input service").await?;
                        }
                    }
                }
                _ = tick.tick() => {}
            }
            match self.drain().await {
                Ok(()) => {}
                Err(DrainError::Gone) => self.recover("recovering the active BLE input service").await?,
                Err(DrainError::Fatal(error)) => return Err(error),
            }
            let busy = self.queue.has_work() || self.pending_return_ack.is_some();
            if !busy {
                self.progress = monotonic_secs();
            } else if monotonic_secs() - self.progress > 4.0 && !self.status.awaiting_unlock_decision() {
                bail!("BLE operation stalled (queued={}).", self.queue.pending_bytes());
            }
            if monotonic_secs() - last_link_check >= 1.0 {
                last_link_check = monotonic_secs();
                if let Some(device) = &self.device {
                    if !device.is_connected().await.unwrap_or(true) {
                        bail!("BLE input disconnected; ending the mirror session.");
                    }
                }
            }
        }
    }

    fn command(&mut self, command: Command) -> Result<()> {
        match command {
            Command::Send(bytes) => {
                if !self.queue.append_records(&bytes) {
                    bail!("Invalid or excessive BLE input backlog");
                }
            }
            Command::AcknowledgeVideo(count) => self.queue.acknowledge_video(count),
            Command::RequestBluetoothVideo(count, nonce) => self.queue.request_bluetooth_video(count, &nonce),
            Command::UnlockDecision(allowed) => {
                if self.status.awaiting_unlock_decision() {
                    self.status.unlock_decision.store(if allowed { 1 } else { 0 }, Ordering::SeqCst);
                }
            }
        }
        Ok(())
    }

    fn returned(&mut self, packet: Vec<u8>) -> Result<()> {
        let acknowledged = self.chars.as_ref().is_some_and(|c| c.return_notify);
        if acknowledged && self.last_return_packet.as_deref() == Some(&packet[..]) {
            // Only the exact last authenticated ciphertext may be retried.
            self.pending_return_ack = Some(self.receive_sequence - 1);
            return Ok(());
        }
        if packet.is_empty() {
            return Ok(());
        }
        let plain = crypto::open(&self.return_keys, self.receive_sequence, &packet)
            .ok_or_else(|| anyhow!("Invalid BLE return record."))?;
        self.receive_sequence += 1;
        if acknowledged {
            self.last_return_packet = Some(packet);
            self.pending_return_ack = Some(self.receive_sequence - 1);
        }
        let _ = self.events.send(Event::Received(plain));
        Ok(())
    }

    async fn read_return(&mut self) -> Result<(), DrainError> {
        let Some(chars) = &self.chars else { return Ok(()) };
        self.input_turn = true;
        let returning = chars.returning.clone();
        let packet = match timeout(Duration::from_secs(4), returning.read()).await {
            Err(_) => return Err(DrainError::Fatal(anyhow!("BLE operation stalled (return read)."))),
            Ok(Err(error)) if is_gone(&error) => return Err(DrainError::Gone),
            Ok(Err(error)) => return Err(DrainError::Fatal(anyhow!("Invalid BLE return record ({error})."))),
            Ok(Ok(packet)) => packet,
        };
        if packet.is_empty() {
            self.next_read = monotonic_secs() + 0.5;
            return Ok(());
        }
        self.returned(packet).map_err(DrainError::Fatal)?;
        self.next_read = 0.0;
        Ok(())
    }

    async fn drain(&mut self) -> Result<(), DrainError> {
        if !self.status.ready.load(Ordering::SeqCst) {
            return Ok(());
        }
        loop {
            if self.status.awaiting_unlock_decision() {
                return Ok(());
            }
            let Some(chars) = &self.chars else { return Ok(()) };
            let input = chars.input.clone();
            let polling = !chars.return_notify && !chars.return_indicate;
            if self.retry_input {
                self.retry_input = false;
                self.input_turn = false;
                // Exact ciphertext only, and only after the phone proved it was not accepted.
                if let Some(packet) = self.in_flight.clone() {
                    self.reliable_write(&input, &packet).await?;
                }
                continue;
            }
            let read_due = polling && monotonic_secs() >= self.next_read;
            if read_due && !self.input_turn {
                self.read_return().await?;
                continue;
            }
            let mut streaming = self.writer.is_some() && !self.reliable_after_recovery;
            if streaming {
                let writer = self.writer.as_ref().unwrap();
                let ready = futures::FutureExt::now_or_never(writer.sendable()).is_some();
                if !ready {
                    if !self.queue.has_work() && self.pending_return_ack.is_none() {
                        self.credit_wait_since = 0.0;
                        return Ok(());
                    }
                    let now = monotonic_secs();
                    if self.credit_wait_since == 0.0 {
                        self.credit_wait_since = now;
                    }
                    if now - self.credit_wait_since < 0.4 {
                        return Ok(());
                    }
                    // BlueZ withholds command credits on a congested shared link.
                    // Submit only a new, unsent record on the acknowledged lane.
                    if !chars.input_reliable {
                        return Ok(());
                    }
                    streaming = false;
                    if !self.queue.latest_motion_only() {
                        eprintln!("BLE command credits stalled; using reliable writes and current motion samples");
                    }
                    self.queue.set_latest_motion_only(true);
                } else {
                    self.credit_wait_since = 0.0;
                    self.queue.set_latest_motion_only(false);
                }
            } else {
                self.queue.set_latest_motion_only(true);
            }
            let single = self.writer.as_ref().map(|w| w.mtu()).unwrap_or(0);
            let mtu = if streaming { if single <= 24 { 128 } else { single.min(512) } } else { 512.min(128.max(single)) };
            let plain = if self.status.startup_pending.load(Ordering::SeqCst) {
                // One decision sealed under this capture's fresh nonce and sequence.
                let allowed = self.status.unlock_decision.load(Ordering::SeqCst) == 1;
                self.status.startup_pending.store(false, Ordering::SeqCst);
                Some(vec![0x71, 0, 0, 0, 1, allowed as u8])
            } else if let Some(sequence) = self.pending_return_ack.take() {
                let mut combined = vec![3, 0, 0, 0, 8];
                combined.extend_from_slice(&sequence.to_be_bytes());
                if mtu > 24 + 13 {
                    if let Some(input) = self.queue.take_packet(mtu - 24 - 13) {
                        combined.extend_from_slice(&input);
                    }
                }
                Some(combined)
            } else {
                self.queue.take_packet(mtu - 24)
            };
            let Some(plain) = plain else {
                if read_due {
                    self.read_return().await?;
                }
                return Ok(());
            };
            let packet = crypto::seal(&self.keys, self.sequence, &plain)
                .ok_or_else(|| DrainError::Fatal(anyhow!("BLE input encryption failed.")))?;
            self.sequence += 1;
            self.input_turn = false;
            self.progress = monotonic_secs();
            if std::env::var_os("DROIDMIRROR_BLE_DEBUG").is_some() {
                eprintln!("BLE input write sequence={} bytes={} streaming={streaming}", self.sequence - 1, packet.len());
            }
            if streaming {
                // A command has no completion; never replay it during recovery.
                self.in_flight = None;
                let writer = self.writer.as_ref().unwrap();
                if single <= 24 {
                    let mut frame = (packet.len() as u16).to_be_bytes().to_vec();
                    frame.extend_from_slice(&packet);
                    for fragment in frame.chunks(single.clamp(3, 20)) {
                        self.stream_write(fragment).await?;
                    }
                } else if let Err(error) = writer.try_send(&packet) {
                    if error.kind() == std::io::ErrorKind::WouldBlock {
                        self.stream_write(&packet).await?;
                    } else {
                        return Err(DrainError::Gone);
                    }
                }
            } else {
                self.in_flight = Some(packet.clone());
                self.reliable_write(&input, &packet).await?;
            }
        }
    }

    async fn stream_write(&mut self, bytes: &[u8]) -> Result<(), DrainError> {
        let writer = self.writer.as_ref().unwrap();
        match timeout(Duration::from_secs(4), writer.send(bytes)).await {
            Err(_) => Err(DrainError::Fatal(anyhow!("BLE operation stalled (streaming write)."))),
            Ok(Err(_)) => Err(DrainError::Gone),
            Ok(Ok(())) => Ok(()),
        }
    }

    async fn reliable_write(&mut self, input: &Characteristic, packet: &[u8]) -> Result<(), DrainError> {
        let started = monotonic_secs();
        let request = CharacteristicWriteRequest { op_type: WriteOp::Request, ..Default::default() };
        match timeout(Duration::from_secs(4), input.write_ext(packet, &request)).await {
            Err(_) => Err(DrainError::Fatal(anyhow!("BLE operation stalled (write)."))),
            Ok(Err(error)) if is_gone(&error) => Err(DrainError::Gone),
            Ok(Err(error)) => Err(DrainError::Fatal(anyhow!("BLE input write failed ({error}; packet={} bytes).", packet.len()))),
            Ok(Ok(())) => {
                let elapsed = monotonic_secs() - started;
                if elapsed > 0.15 {
                    eprintln!("BLE input slow completion: {:.0} ms, packet={} bytes", elapsed * 1000.0, packet.len());
                }
                self.in_flight = None;
                self.progress = monotonic_secs();
                Ok(())
            }
        }
    }
}

enum DrainError {
    Gone,
    Fatal(anyhow::Error),
}
