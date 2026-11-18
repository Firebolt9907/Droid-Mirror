//! Phone audio over Wi-Fi (port of the Mac's independent audio lane).
//!
//! The lane is a separate loopback connection (paired Iroh QUIC audio port, or
//! a wireless-ADB forward to `localabstract:droidmirror_audio_upgrade`) with its
//! own fresh `DMAUDIO1` proof handshake. After acceptance the phone sends a
//! DMBT0006 stream of type-7 records: big-endian capture PTS (µs) followed by
//! 48 kHz stereo s16le PCM. PCM goes to PipeWire (`pw-play`) or PulseAudio
//! (`pacat`), which provide the jitter buffer.

use crate::crypto;
use std::io::{Read, Write};
use std::net::{Ipv4Addr, SocketAddrV4, TcpStream};
use std::process::{Child, Command, Stdio};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::Arc;
use std::time::Duration;

pub struct AudioLane {
    stop: Arc<AtomicBool>,
    socket: TcpStream,
}

impl AudioLane {
    pub fn stop(&self) {
        self.stop.store(true, Ordering::SeqCst);
        let _ = self.socket.shutdown(std::net::Shutdown::Both);
    }
}

fn player(buffer_ms: u32) -> Option<Child> {
    let latency = format!("{}ms", buffer_ms.clamp(40, 400));
    let candidates: [(&str, Vec<String>); 2] = [
        ("pw-play", vec!["--format=s16".into(), "--rate=48000".into(), "--channels=2".into(), format!("--latency={latency}"),
            "--media-role=Music".into(), "-P".into(), "{ \"node.name\": \"droidmirror-phone-audio\", \"media.name\": \"Phone audio (DroidMirror)\" }".into(), "-".into()]),
        ("pacat", vec!["--playback".into(), "--format=s16le".into(), "--rate=48000".into(), "--channels=2".into(),
            format!("--latency-msec={}", buffer_ms.clamp(40, 400)), "--client-name=DroidMirror".into(), "--stream-name=Phone audio".into()]),
    ];
    for (program, args) in candidates {
        if let Ok(child) = Command::new(program).args(&args).stdin(Stdio::piped()).stdout(Stdio::null()).stderr(Stdio::null()).spawn() {
            return Some(child);
        }
    }
    None
}

/// Connects and authenticates the lane; returns once PCM is flowing (or fails).
/// `on_end` runs on the lane thread when audio stops for any reason.
pub fn start(port: u16, key: [u8; 32], buffer_ms: u32, on_end: impl FnOnce(bool) + Send + 'static) -> Option<AudioLane> {
    let mut socket = TcpStream::connect_timeout(&SocketAddrV4::new(Ipv4Addr::LOCALHOST, port).into(), Duration::from_secs(2)).ok()?;
    let _ = socket.set_read_timeout(Some(Duration::from_secs(2)));
    let _ = socket.set_nodelay(true);
    let mut hello = [0u8; 40];
    socket.read_exact(&mut hello).ok()?;
    if &hello[..8] != b"DMAUDIO1" {
        return None;
    }
    let nonce = &hello[8..40];
    socket.write_all(&crypto::upgrade_proof(&key, "audio client", nonce, &[])).ok()?;
    let mut response = [0u8; 32];
    socket.read_exact(&mut response).ok()?;
    if !crypto::equal(&response, &crypto::upgrade_proof(&key, "audio server", nonce, &[])) {
        return None;
    }
    socket.write_all(&[1]).ok()?;
    // After acceptance the phone may stay idle (paused media): no read timeout.
    let _ = socket.set_read_timeout(None);
    let stop = Arc::new(AtomicBool::new(false));
    let lane = AudioLane { stop: stop.clone(), socket: socket.try_clone().ok()? };
    std::thread::spawn(move || {
        let mut output = player(buffer_ms);
        let failed = output.is_none() || pump(&mut socket, output.as_mut().and_then(|c| c.stdin.as_mut()), &stop).is_err();
        if let Some(mut child) = output {
            drop(child.stdin.take());
            let _ = child.kill();
            let _ = child.wait();
        }
        on_end(failed && !stop.load(Ordering::SeqCst));
    });
    Some(lane)
}

fn pump(socket: &mut TcpStream, mut sink: Option<&mut std::process::ChildStdin>, stop: &AtomicBool) -> std::io::Result<()> {
    let mut magic = [0u8; 8];
    socket.read_exact(&mut magic)?;
    if &magic != b"DMBT0006" {
        return Err(std::io::Error::other("invalid audio stream"));
    }
    let mut header = [0u8; 5];
    let mut payload = vec![0u8; 4104];
    while !stop.load(Ordering::SeqCst) {
        socket.read_exact(&mut header)?;
        let length = u32::from_be_bytes(header[1..5].try_into().unwrap()) as usize;
        if length > payload.len() {
            return Err(std::io::Error::other("oversized audio record"));
        }
        socket.read_exact(&mut payload[..length])?;
        match header[0] {
            7 if length >= 12 && length % 4 == 0 => {
                if let Some(sink) = sink.as_deref_mut() {
                    sink.write_all(&payload[8..length])?;
                }
            }
            6 if length == 1 => {
                if payload[0] & 4 != 0 {
                    return Err(std::io::Error::other("phone audio capture failed"));
                }
            }
            1 | 5 => {}
            _ => return Err(std::io::Error::other("unexpected audio record")),
        }
    }
    Ok(())
}
