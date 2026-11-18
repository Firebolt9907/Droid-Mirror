//! DroidMirror Linux Bluetooth helper.
//!
//! Command-line contract (matches Native/ClassicBluetoothBridge.m on macOS so
//! the host logic ports one-to-one):
//!   droidmirror-bluetooth --list                 JSON of BlueZ-paired devices
//!   droidmirror-bluetooth --paired               JSON of phones with a DroidMirror key
//!   droidmirror-bluetooth --pair ADDRESS         read the pairing code (32 raw bytes or base64) from stdin
//!   droidmirror-bluetooth --has-pairing ADDRESS  prints "paired" or "unpaired"
//!   droidmirror-bluetooth --forget ADDRESS       removes the stored key
//!   droidmirror-bluetooth --qr-pair ADDRESS       QR-code pairing invitation (prints QR <url>, SAVED/FAILED)
//!   droidmirror-bluetooth --notifications ADDRESS background notification session (JSON lines)
//!   droidmirror-bluetooth ADDRESS                runs one mirror session

mod audio;
mod ble_input;
mod bridge;
mod crypto;
mod notify;
mod qr;
mod queue;
mod store;
mod wire;

use base64::Engine;
use std::io::Read;

fn usage() -> ! {
    eprintln!("Usage: droidmirror-bluetooth ADDRESS | --list | --paired | --pair ADDRESS | --has-pairing ADDRESS | --forget ADDRESS | --notifications ADDRESS");
    std::process::exit(2)
}

fn address(arg: Option<&String>) -> bluer::Address {
    arg.and_then(|a| store::normalize(a)).unwrap_or_else(|| usage())
}

async fn list() -> anyhow::Result<()> {
    let session = bluer::Session::new().await?;
    let adapter = session.default_adapter().await?;
    let mut devices = Vec::new();
    for address in adapter.device_addresses().await? {
        let device = adapter.device(address)?;
        if !device.is_paired().await.unwrap_or(false) {
            continue;
        }
        let name = device.alias().await.unwrap_or_else(|_| "Bluetooth device".into());
        let icon = device.icon().await.ok().flatten().unwrap_or_default();
        let connected = device.is_connected().await.unwrap_or(false);
        devices.push(serde_json::json!({
            "address": address.to_string(),
            "name": name,
            "icon": icon,
            "connected": connected,
            "droidmirror": store::load(address).is_some(),
        }));
    }
    println!("{}", serde_json::Value::Array(devices));
    Ok(())
}

fn main() {
    let args: Vec<String> = std::env::args().skip(1).collect();
    let runtime = tokio::runtime::Builder::new_multi_thread().enable_all().worker_threads(2).build().expect("runtime");
    let code = match args.first().map(String::as_str) {
        Some("--list") => match runtime.block_on(list()) {
            Ok(()) => 0,
            Err(error) => {
                eprintln!("Could not list Bluetooth devices: {error}");
                1
            }
        },
        Some("--paired") => {
            let phones: Vec<String> = store::paired().iter().map(|a| a.to_string()).collect();
            println!("{}", serde_json::json!(phones));
            0
        }
        Some("--pair") => {
            let address = address(args.get(1));
            let mut input = Vec::new();
            if std::io::stdin().read_to_end(&mut input).is_err() {
                std::process::exit(2);
            }
            let key: Option<[u8; 32]> = if input.len() == 32 {
                input.as_slice().try_into().ok()
            } else {
                let text = String::from_utf8_lossy(&input);
                base64::engine::general_purpose::STANDARD.decode(text.trim()).ok().and_then(|k| k.try_into().ok())
            };
            input.fill(0);
            match key {
                Some(mut key) => {
                    let result = store::save(address, &key);
                    key.fill(0);
                    match result {
                        Ok(()) => 0,
                        Err(error) => {
                            eprintln!("Could not save the DroidMirror pairing code: {error}");
                            1
                        }
                    }
                }
                None => {
                    eprintln!("Paste the full BLE pairing code shown in the Android companion.");
                    2
                }
            }
        }
        Some("--has-pairing") => {
            println!("{}", if store::load(address(args.get(1))).is_some() { "paired" } else { "unpaired" });
            0
        }
        Some("--forget") => match store::remove(address(args.get(1))) {
            Ok(()) => 0,
            Err(error) => {
                eprintln!("Could not remove pairing: {error}");
                1
            }
        },
        Some("--qr-pair") => {
            let address = address(args.get(1));
            match runtime.block_on(qr::run(address)) {
                Ok(()) => 0,
                Err(error) => {
                    println!("FAILED {error:#}");
                    1
                }
            }
        }
        Some("--notifications") => {
            let address = address(args.get(1));
            let Some(key) = store::load(address) else {
                eprintln!("Pair once in DroidMirror using the code from the Android companion.");
                std::process::exit(2);
            };
            match runtime.block_on(notify::run(address, key)) {
                Ok(()) => 0,
                Err(error) => {
                    eprintln!("{error:#}");
                    1
                }
            }
        }
        Some(arg) if !arg.starts_with("--") && args.len() == 1 => {
            let address = address(args.first());
            let Some(key) = store::load(address) else {
                eprintln!("Pair once in DroidMirror using the code from the Android companion.");
                std::process::exit(2);
            };
            match runtime.block_on(bridge::Bridge::new(address, key).run()) {
                Ok(()) => 0,
                Err(error) => {
                    eprintln!("{error:#}");
                    1
                }
            }
        }
        _ => usage(),
    };
    runtime.shutdown_timeout(std::time::Duration::from_millis(250));
    std::process::exit(code);
}
