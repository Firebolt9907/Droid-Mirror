//! QR-code pairing (port of Sources/DroidMirror/QRPairingView.swift and
//! QRPairingProtocol.swift).
//!
//! This computer publishes a temporary GATT service for two minutes and prints
//! `QR <url>`; the phone scans the code, connects, and writes its existing
//! pairing key sealed with AES-256-GCM under the one-use secret in the code
//! (authenticated data binds the service and this computer's address). After
//! the key is saved, the phone reads a 16-byte HMAC acknowledgement. The secret
//! only protects delivery; it never becomes the pairing key.

use crate::store;
use aes_gcm::aead::{Aead, KeyInit, Payload};
use aes_gcm::{Aes256Gcm, Nonce};
use anyhow::{anyhow, bail, Result};
use base64::Engine;
use bluer::gatt::local::{
    Application, Characteristic, CharacteristicRead, CharacteristicWrite, CharacteristicWriteMethod, ReqError, Service,
};
use bluer::Address;
use rand::RngCore;
use std::io::Write;
use std::sync::{Arc, Mutex};
use std::time::Duration;
use uuid::Uuid;

const CHARACTERISTIC: Uuid = Uuid::from_u128(0xA946DDA2_7E71_4ACD_B670_F77C3D715891);

fn context(service: &str, computer: &str) -> Vec<u8> {
    format!("DroidMirror QR key transfer v1|{}|{}", service.to_uppercase(), computer.to_uppercase()).into_bytes()
}

pub fn open(packet: &[u8], secret: &[u8; 32], service: &str, computer: &str) -> Option<[u8; 32]> {
    if packet.len() != 60 {
        return None;
    }
    let cipher = Aes256Gcm::new(secret.into());
    let plain = cipher
        .decrypt(Nonce::from_slice(&packet[..12]), Payload { msg: &packet[12..], aad: &context(service, computer) })
        .ok()?;
    plain.try_into().ok()
}

pub fn acknowledgement(packet: &[u8], secret: &[u8; 32], service: &str, computer: &str) -> Vec<u8> {
    crate::crypto::hmac(secret, &[&context(service, computer), b"|saved|", packet])[..16].to_vec()
}

#[derive(Default)]
struct Transfer {
    buffer: Vec<u8>,
    acknowledgement: Option<Vec<u8>>,
    done: bool,
}

fn emit(line: &str) {
    let mut out = std::io::stdout().lock();
    let _ = writeln!(out, "{line}");
    let _ = out.flush();
}

/// Runs one QR pairing invitation for `phone`; returns after success or expiry.
pub async fn run(phone: Address) -> Result<()> {
    let session = bluer::Session::new().await?;
    let adapter = session.default_adapter().await?;
    adapter.set_powered(true).await.ok();
    let computer = adapter.address().await?.to_string().to_uppercase();
    let service_id = Uuid::new_v4().to_string().to_uppercase();
    let mut secret = [0u8; 32];
    rand::thread_rng().fill_bytes(&mut secret);
    let state = Arc::new(Mutex::new(Transfer::default()));

    let write_state = state.clone();
    let (service_w, computer_w) = (service_id.clone(), computer.clone());
    let read_state = state.clone();
    let application = Application {
        services: vec![Service {
            uuid: service_id.parse()?,
            primary: true,
            characteristics: vec![Characteristic {
                uuid: CHARACTERISTIC,
                write: Some(CharacteristicWrite {
                    write: true,
                    method: CharacteristicWriteMethod::Fun(Box::new(move |value, request| {
                        let state = write_state.clone();
                        let (service, computer) = (service_w.clone(), computer_w.clone());
                        Box::pin(async move {
                            let mut transfer = state.lock().unwrap();
                            if transfer.done || request.offset != 0 || value.is_empty() || value.len() > 20 || transfer.buffer.len() + value.len() > 60 {
                                transfer.buffer.clear();
                                return Err(ReqError::InvalidValueLength);
                            }
                            transfer.buffer.extend_from_slice(&value);
                            if transfer.buffer.len() < 60 {
                                return Ok(());
                            }
                            let packet = std::mem::take(&mut transfer.buffer);
                            let Some(mut key) = open(&packet, &secret, &service, &computer) else {
                                return Err(ReqError::Failed);
                            };
                            // Consume the invitation before saving: no replay or second delivery.
                            transfer.done = true;
                            let saved = store::save(phone, &key);
                            key.fill(0);
                            match saved {
                                Ok(()) => {
                                    transfer.acknowledgement = Some(acknowledgement(&packet, &secret, &service, &computer));
                                    emit("SAVED");
                                    Ok(())
                                }
                                Err(error) => {
                                    emit(&format!("FAILED Could not save the pairing code: {error}"));
                                    Err(ReqError::Failed)
                                }
                            }
                        })
                    })),
                    ..Default::default()
                }),
                read: Some(CharacteristicRead {
                    read: true,
                    fun: Box::new(move |request| {
                        let state = read_state.clone();
                        Box::pin(async move {
                            let transfer = state.lock().unwrap();
                            match (&transfer.acknowledgement, request.offset) {
                                (Some(ack), 0) => Ok(ack.clone()),
                                _ => Err(ReqError::NotPermitted),
                            }
                        })
                    }),
                    ..Default::default()
                }),
                ..Default::default()
            }],
            ..Default::default()
        }],
        ..Default::default()
    };
    let _application = adapter.serve_gatt_application(application).await.map_err(|e| anyhow!("Bluetooth pairing service could not start: {e}"))?;
    let _advertisement = adapter
        .advertise(bluer::adv::Advertisement {
            advertisement_type: bluer::adv::Type::Peripheral,
            service_uuids: [service_id.parse()?].into_iter().collect(),
            ..Default::default()
        })
        .await
        .map_err(|e| anyhow!("Bluetooth advertising failed ({e}). Use manual code entry."))?;
    let encoded = base64::engine::general_purpose::URL_SAFE_NO_PAD.encode(secret);
    emit(&format!("QR droidmirror-pair://v1?service={service_id}&mac={computer}&secret={encoded}"));
    let deadline = tokio::time::Instant::now() + Duration::from_secs(120);
    loop {
        tokio::time::sleep(Duration::from_millis(250)).await;
        let acknowledged = state.lock().unwrap().acknowledgement.is_some();
        if acknowledged {
            // Leave time for the phone's acknowledgement read.
            tokio::time::sleep(Duration::from_secs(5)).await;
            secret.fill(0);
            return Ok(());
        }
        if tokio::time::Instant::now() >= deadline {
            secret.fill(0);
            bail!("QR code expired. Close and reopen to try again.");
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn opens_sealed_key_and_binds_context() {
        let secret = [3u8; 32];
        let key = [9u8; 32];
        let cipher = Aes256Gcm::new((&secret).into());
        let nonce = [1u8; 12];
        let sealed = cipher.encrypt(Nonce::from_slice(&nonce), Payload { msg: &key, aad: &context("abc", "aa:bb") }).unwrap();
        let packet = [&nonce[..], &sealed[..]].concat();
        assert_eq!(open(&packet, &secret, "ABC", "AA:BB"), Some(key));
        assert_eq!(open(&packet, &secret, "ABD", "AA:BB"), None);
        assert_eq!(acknowledgement(&packet, &secret, "abc", "aa:bb").len(), 16);
    }
}
