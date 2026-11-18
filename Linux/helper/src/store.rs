//! Per-phone pairing storage for Linux.
//!
//! macOS keeps one Keychain item per phone (`app.droidmirror.classic.ble.v2`,
//! account = Bluetooth address). Linux keeps one owner-only file per phone in
//! `$XDG_CONFIG_HOME/droidmirror/phones/`, so any number of phones can be
//! paired with this laptop at the same time.

use crate::crypto;
use base64::Engine;
use bluer::Address;
use std::fs;
use std::io::Write;
use std::os::unix::fs::{OpenOptionsExt, PermissionsExt};
use std::path::PathBuf;

pub fn config_dir() -> PathBuf {
    let base = std::env::var_os("XDG_CONFIG_HOME")
        .map(PathBuf::from)
        .unwrap_or_else(|| PathBuf::from(std::env::var_os("HOME").unwrap_or_default()).join(".config"));
    base.join("droidmirror")
}

fn phones_dir() -> PathBuf {
    config_dir().join("phones")
}

pub fn normalize(address: &str) -> Option<Address> {
    address.replace('-', ":").to_uppercase().parse().ok()
}

fn key_path(address: Address) -> PathBuf {
    phones_dir().join(format!("{}.key", address.to_string().replace(':', "_")))
}

fn write_private(path: &PathBuf, contents: &[u8]) -> std::io::Result<()> {
    if let Some(parent) = path.parent() {
        fs::create_dir_all(parent)?;
        fs::set_permissions(parent, fs::Permissions::from_mode(0o700))?;
    }
    let temporary = path.with_extension("tmp");
    {
        let mut file = fs::OpenOptions::new().create(true).truncate(true).write(true).mode(0o600).open(&temporary)?;
        file.write_all(contents)?;
        file.sync_all()?;
    }
    fs::rename(temporary, path)
}

pub fn load(address: Address) -> Option<[u8; 32]> {
    let text = fs::read_to_string(key_path(address)).ok()?;
    let bytes = base64::engine::general_purpose::STANDARD.decode(text.trim()).ok()?;
    bytes.try_into().ok()
}

pub fn save(address: Address, key: &[u8; 32]) -> std::io::Result<()> {
    let encoded = base64::engine::general_purpose::STANDARD.encode(key);
    write_private(&key_path(address), encoded.as_bytes())
}

pub fn remove(address: Address) -> std::io::Result<()> {
    match fs::remove_file(key_path(address)) {
        Err(error) if error.kind() != std::io::ErrorKind::NotFound => Err(error),
        _ => Ok(()),
    }
}

pub fn paired() -> Vec<Address> {
    let mut out = Vec::new();
    if let Ok(entries) = fs::read_dir(phones_dir()) {
        for entry in entries.flatten() {
            let name = entry.file_name().to_string_lossy().to_string();
            if let Some(stem) = name.strip_suffix(".key") {
                if let Some(address) = normalize(&stem.replace('_', ":")) {
                    if load(address).is_some() {
                        out.push(address);
                    }
                }
            }
        }
    }
    out.sort();
    out
}

/// Authenticated LE identities, scoped by the pairing's discovery UUID so a
/// changed pairing code never trusts an old peer (same as the Mac).
fn peers_path() -> PathBuf {
    config_dir().join("ble-peers.json")
}

fn scope(pairing: &[u8; 32]) -> String {
    let notification = crypto::notification_pairing_key(pairing);
    uuid::Uuid::from_bytes(crypto::discovery_uuid(&notification)).to_string()
}

pub fn remembered_le_peer(pairing: &[u8; 32]) -> Option<Address> {
    let text = fs::read_to_string(peers_path()).ok()?;
    let value: serde_json::Value = serde_json::from_str(&text).ok()?;
    value.get(scope(pairing))?.as_str()?.parse().ok()
}

pub fn remember_le_peer(pairing: &[u8; 32], peer: Address) {
    let mut value: serde_json::Value = fs::read_to_string(peers_path())
        .ok()
        .and_then(|t| serde_json::from_str(&t).ok())
        .unwrap_or_else(|| serde_json::json!({}));
    if let Some(map) = value.as_object_mut() {
        map.insert(scope(pairing), serde_json::Value::String(peer.to_string()));
        let _ = write_private(&peers_path(), value.to_string().as_bytes());
    }
}
