//! Port of Native/BleInputCrypto.c (CommonCrypto) to RustCrypto.
//!
//! The byte layout is shared with the Android companion's BleInputCrypto.java
//! and must stay identical: HMAC-SHA256 derivations, AES-256-CTR with a full
//! 128-bit big-endian counter and a truncated 16-byte HMAC tag.

use aes::Aes256;
use ctr::cipher::{KeyIvInit, StreamCipher};
use hmac::{Hmac, Mac};
use sha2::{Digest, Sha256};

type HmacSha256 = Hmac<Sha256>;
type Aes256Ctr = ctr::Ctr128BE<Aes256>;

pub fn hmac(key: &[u8], parts: &[&[u8]]) -> [u8; 32] {
    let mut mac = HmacSha256::new_from_slice(key).expect("HMAC accepts any key length");
    for part in parts {
        mac.update(part);
    }
    mac.finalize().into_bytes().into()
}

pub fn sha256_hex(data: &[u8]) -> String {
    Sha256::digest(data).iter().map(|b| format!("{b:02x}")).collect()
}

/// Constant-time comparison.
pub fn equal(a: &[u8], b: &[u8]) -> bool {
    if a.len() != b.len() {
        return false;
    }
    a.iter().zip(b).fold(0u8, |acc, (x, y)| acc | (x ^ y)) == 0
}

#[derive(Clone, Default)]
pub struct Keys {
    pub encryption: [u8; 32],
    pub authentication: [u8; 32],
}

impl Drop for Keys {
    fn drop(&mut self) {
        self.encryption.fill(0);
        self.authentication.fill(0);
    }
}

pub fn notification_pairing_key(pairing: &[u8; 32]) -> [u8; 32] {
    hmac(pairing, &[b"DroidMirror notifications pairing v1"])
}

/// Discovery hint only; a peer advertising it still has to authenticate.
pub fn discovery_uuid(notification: &[u8; 32]) -> [u8; 16] {
    let digest = hmac(notification, &[b"DroidMirror BLE discovery v1"]);
    let mut uuid = [0u8; 16];
    uuid.copy_from_slice(&digest[..16]);
    uuid[6] = (uuid[6] & 0x0f) | 0x80;
    uuid[8] = (uuid[8] & 0x3f) | 0x80;
    uuid
}

pub fn session_key(pairing: &[u8; 32], nonce: &[u8]) -> [u8; 32] {
    hmac(pairing, &[b"DroidMirror BLE session v1", nonce])
}

pub fn input_keys(session: &[u8; 32]) -> Keys {
    Keys {
        encryption: hmac(session, &[b"DroidMirror BLE encryption v1"]),
        authentication: hmac(session, &[b"DroidMirror BLE authentication v1"]),
    }
}

pub fn output_keys(session: &[u8; 32]) -> Keys {
    Keys {
        encryption: hmac(session, &[b"DroidMirror BLE return encryption v1"]),
        authentication: hmac(session, &[b"DroidMirror BLE return authentication v1"]),
    }
}

pub fn input_proof(keys: &Keys, challenge: &[u8]) -> [u8; 32] {
    hmac(&keys.authentication, &[b"DroidMirror BLE proof v1", challenge])
}

pub fn clock_proof(keys: &Keys, time: &[u8]) -> [u8; 32] {
    hmac(&keys.authentication, &[b"DroidMirror BLE clock v1", time])
}

pub fn resume_proof(keys: &Keys, challenge: &[u8], next: &[u8]) -> [u8; 32] {
    hmac(&keys.authentication, &[b"DroidMirror BLE resume v1", challenge, next])
}

fn iv(sequence: &[u8]) -> [u8; 16] {
    let mut iv = [0u8; 16];
    iv[..8].copy_from_slice(b"DMINPUT1");
    iv[8..].copy_from_slice(sequence);
    iv
}

/// Seals one authenticated input record: seq(8) || ciphertext || tag(16).
pub fn seal(keys: &Keys, sequence: u64, plain: &[u8]) -> Option<Vec<u8>> {
    if sequence == 0 || sequence >= i64::MAX as u64 || plain.is_empty() || plain.len() > 488 {
        return None;
    }
    let mut packet = Vec::with_capacity(plain.len() + 24);
    packet.extend_from_slice(&sequence.to_be_bytes());
    packet.extend_from_slice(plain);
    let mut cipher = Aes256Ctr::new(&keys.encryption.into(), &iv(&packet[..8]).into());
    cipher.apply_keystream(&mut packet[8..]);
    let tag = hmac(&keys.authentication, &[&packet]);
    packet.extend_from_slice(&tag[..16]);
    Some(packet)
}

/// Opens a return record whose sequence must equal `sequence`.
pub fn open(keys: &Keys, sequence: u64, packet: &[u8]) -> Option<Vec<u8>> {
    if sequence == 0 || sequence >= i64::MAX as u64 || packet.len() <= 24 || packet.len() > 512 {
        return None;
    }
    let received = u64::from_be_bytes(packet[..8].try_into().unwrap());
    if received != sequence {
        return None;
    }
    let body = &packet[..packet.len() - 16];
    let tag = hmac(&keys.authentication, &[body]);
    if !equal(&tag[..16], &packet[packet.len() - 16..]) {
        return None;
    }
    let mut plain = packet[8..packet.len() - 16].to_vec();
    let mut cipher = Aes256Ctr::new(&keys.encryption.into(), &iv(&packet[..8]).into());
    cipher.apply_keystream(&mut plain);
    Some(plain)
}

/// HMAC proofs for the authenticated Wi-Fi/USB/QUIC video handoff.
pub fn upgrade_proof(key: &[u8; 32], direction: &str, nonce: &[u8], extra: &[u8]) -> [u8; 32] {
    let label = format!("DroidMirror Wi-Fi {direction} v1");
    hmac(key, &[label.as_bytes(), nonce, extra])
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn seal_open_round_trip() {
        let pairing = [7u8; 32];
        let session = session_key(&pairing, &[9u8; 32]);
        let keys = input_keys(&session);
        let packet = seal(&keys, 5, b"hello").unwrap();
        assert_eq!(packet.len(), 5 + 24);
        assert_eq!(open(&keys, 5, &packet).unwrap(), b"hello");
        assert!(open(&keys, 6, &packet).is_none());
        let mut tampered = packet.clone();
        tampered[10] ^= 1;
        assert!(open(&keys, 5, &tampered).is_none());
    }

    #[test]
    fn discovery_uuid_is_rfc4122_variant() {
        let uuid = discovery_uuid(&[1u8; 32]);
        assert_eq!(uuid[6] & 0xf0, 0x80);
        assert_eq!(uuid[8] & 0xc0, 0x80);
    }
}

#[cfg(test)]
mod cross {
    use super::*;
    /// Vectors produced by the Android companion's BleInputCrypto.java.
    #[test]
    fn matches_android_vectors() {
        let session = [3u8; 32];
        let plain = b"hello world, this is longer than one AES block!";
        let hex = |v: Vec<u8>| v.iter().map(|b| format!("{b:02x}")).collect::<String>();
        assert_eq!(
            hex(seal(&input_keys(&session), 1, plain).unwrap()),
            "0000000000000001fe47da7ffc50bc04e4e38c1738a006ac62eba913c196444edcd8447e30fef44f35116440ff2422c619963c1e270c763d064ea123cb2538daaf86a826fe4d91"
        );
        assert_eq!(
            hex(seal(&output_keys(&session), 1, plain).unwrap()),
            "000000000000000139d44d48a1cd8211ead01b171950d0c14283cf997433b1e9b9caeee585aa6b91ee64a150cc27086f9cf492cab0254eefc5e89d1e5a74f9461894204e5fa499"
        );
    }
}
