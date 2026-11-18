# DroidMirror for Linux

Mirror and control Android phones from a Linux laptop, using the same Android
companion app, Bluetooth protocol and security model as the Mac app.

Status: **early port, in active testing**. Verified on a Pixel 8: the
authenticated background session (notifications, media, Focus state, endpoint
publication) and its reconnection after app updates. Bluetooth mirroring is
implemented but not yet verified end to end. See [Feature parity](#feature-parity).

## Multiple phones and multiple computers

* **One computer, many phones.** Every phone paired in system Bluetooth settings
  is listed. Each phone keeps its own private DroidMirror pairing code
  (`~/.config/droidmirror/phones/<address>.key`, mode 0600). Mirror sessions and
  background connections are independent per phone.
* **One phone, two computers.** The Android companion trusts up to two
  computers (Macs and/or Linux laptops). Every computer has its own pairing code
  and there is no primary computer. Background features work for each computer
  while that computer has an authenticated Bluetooth session with the phone.
  See [Android changes](#android-changes).

## Background features

DroidMirror runs as a background GTK application. XDG autostart launches it
with `--background` at login. Closing the window keeps it running, and **Quit
DroidMirror** in the window menu ends mirrors and phone connections. Each phone
set up with DroidMirror gets one encrypted background session
(`droidmirror-bluetooth --notifications ADDRESS`), and every feature is gated on
that live connection:

| Feature | Linux implementation |
| --- | --- |
| Notifications, actions, inline replies, dismissal | freedesktop notifications; clicking opens the app in a mirror |
| Clipboard text, both ways | wl-clipboard (Wayland data-control), else Klipper, else GTK clipboard |
| Links, both ways | default browser; **Send a link to this phone…** / `droidmirror open-on-phone URL` |
| Phone media | MPRIS player ("&lt;phone&gt; (DroidMirror)") in desktop media controls and media keys |
| Focus / Do Not Disturb, both ways | GNOME `show-banners`, or the notification server's Inhibit (KDE) |
| Phone hotspot | phone menu → **Turn on/off phone hotspot** |
| Continue browsing (handoff) | "Continue from your phone" list, optional notifications |
| Wear OS companion | battery via UPower; the watch can ring this computer |
| Wireless ADB | optional `adb connect` to the endpoint the phone publishes |
| Presence beacon (left-behind alerts) | BlueZ LE advertisement (see Known issues) |

## Feature parity

Implemented and verified on hardware: background session, notifications,
media/MPRIS, Focus state queries, endpoint publication, reconnects.

Implemented, waiting on device verification: Bluetooth mirroring
(Classic L2CAP video + BLE input), direct-IP (Iroh) and wireless-ADB video
upgrades, phone audio over Wi-Fi (PipeWire/PulseAudio playback), QR-code pairing
(needs `qrencode`), clipboard text, links, hotspot, handoff, Wear OS,
Wi-Fi Aware video.

Also implemented: file transfer both ways (drop files on a phone in the
DroidMirror window, or **Send files to this phone…**; files copied on the phone
are saved in Downloads), phone apps as application-menu launchers (opt-in;
verified with a live 288-app catalog), and USB accessory (AOA) video. USB needs
the udev rule in `Linux/data/70-droidmirror-usb.rules`.

Live Activities appear as resident, silently updating notifications with a
progress value (there's no GTK menu-bar widget equivalent).

Not ported: the Continuity Camera device (needs the non-standard v4l2loopback
kernel module), trackpad haptics and Mac-only Apple Music sync. Touch ID is replaced by a confirmation dialog for saved-PIN unlock.

### Wi-Fi Aware

During a mirror session the phone publishes a Wi-Fi Aware service keyed to the
connected computer. The computer proves the pairing key and opens a NAN data
path secured by a key-derived passphrase. That path is relayed into the same
authenticated video-upgrade handshake as LAN and ADB video. On Linux this needs
a Wi-Fi driver with the NAN interface mode (`iw list`) and access to
wpa_supplicant's control socket (`ctrl_interface=DIR=/run/wpa_supplicant
GROUP=<your group>`). Many laptop adapters, including Intel AX201, lack NAN. The
app then shows Wi-Fi Aware as unavailable and uses the other paths.

## Known issues

* On the development laptop (Intel AX201, kernel 7.0, BlueZ 5.88 with LL privacy
  enabled), every LE advertisement is rejected with "Invalid Parameters". That
  disables the presence beacon and QR pairing on that machine. Disabling BlueZ's
  experimental LL privacy, which needs root, is the likely fix; use manual code
  entry meanwhile.
* Shizuku authorization can't be granted over ADB. Approve DroidMirror in the
  Shizuku app.

## Requirements

* BlueZ 5.62 or newer, with Bluetooth Classic (BR/EDR) and LE on the same adapter.
* Rust 1.91+, meson, ninja, pkg-config, SDL3, FFmpeg development packages
  (`libavcodec`, `libavformat`, `libavutil`, `libswresample`), `libusb-1.0` and
  D-Bus development headers.
* Python 3 with PyGObject, GTK 4 and libadwaita 1.5 or newer.
* The Android companion app with Shizuku, as described in the main
  [README](../README.md). Phones need a companion build with multi-computer
  support to use a Mac and a Linux laptop side by side.

Arch / CachyOS: `sudo pacman -S rust meson ninja sdl3 ffmpeg libusb dbus python-gobject gtk4 libadwaita`

Debian / Ubuntu (24.10+): `sudo apt install cargo meson ninja-build pkg-config libsdl3-dev libavcodec-dev libavformat-dev libavutil-dev libswresample-dev libusb-1.0-0-dev libdbus-1-dev python3-gi gir1.2-gtk-4.0 gir1.2-adw-1`

## Build and install

```sh
Linux/build-linux.sh             # builds into Linux/build
Linux/build-linux.sh --install   # also installs for this user (~/.local)
```

Run from the checkout without installing:

```sh
PYTHONPATH=Linux/app python3 -m droidmirror_linux
```

End active mirror sessions before reinstalling. A running helper keeps
executing its old binary until its session ends.

## Set up a phone

1. Pair the phone with the laptop in your desktop's Bluetooth settings and
   accept the matching code on both devices.
2. On the phone, open DroidMirror. In **Connect Bluetooth**, choose this
   laptop, then authorize Shizuku.
3. In **Pair DroidMirror**, tap **Show pairing code**. On the laptop, press
   **Set up…** next to the phone and paste the code. From a terminal:
   `droidmirror pair <phone address>`.
4. On the phone, tap **Enable background bridge**. Lock the phone, then press
   **Mirror** on the laptop.

To add another computer to the same phone, run the phone's setup again and
choose the other computer. Existing computers stay trusted.

### Command line

```sh
droidmirror list                       # paired Bluetooth devices and setup state
droidmirror pair 94:45:60:27:E5:27     # prompts for (or reads from stdin) the private code
droidmirror mirror 94:45:60:27:E5:27   # one session; run several for several phones
droidmirror forget 94:45:60:27:E5:27   # removes only the DroidMirror code
```

`mirror --unlock ask|always|never` sets whether the PIN saved on the phone may
be entered before video starts. Linux has no Touch ID equivalent, so **Ask**
shows a confirmation dialog (or a terminal prompt) after the phone has
authenticated.

## How it works

```
  phone (Android companion, Shizuku)                 laptop
  ─────────────────────────────────                  ──────────────────────────────────────────────
  Classic L2CAP PSM 0xD001 listener ──video──▶ droidmirror-bluetooth (Rust, BlueZ) ──loopback──▶ droidmirror-renderer
  per-session BLE input service    ◀──input── │  · DMBT0006 wire parser                    (DroidMirror's scrcpy,
                                   ──events─▶ │  · BLE HMAC/AES-CTR sessions              --external-video-port /
  Iroh direct-IP / ADB upgrade     ──video──▶ │  · Iroh peer transport (direct IP)        --external-control-port)
                                              └─ stdout: LISTENING / READY / EVENT …
                                                 stdin:  UPGRADE_PEER / UPGRADE <port> / UNLOCK_DECISION
  background BLE bridge (7e57b000) ◀──────▶ droidmirror-bluetooth --notifications (JSON lines ⇄ desktop notifications)
                                              droidmirror (Python, GTK 4) — phones, pairing, sessions, logs
```

* `Linux/helper` is a port of `Native/ClassicBluetoothBridge.m`,
  `BleInputTransport.m`, `BleInputQueue.m`, `BleInputCrypto.c` and
  `ClassicBluetoothWire.c`. It keeps the exact wire formats, key derivations and
  stdin/stdout contract. Its crypto is tested against vectors produced by the
  Android companion's `BleInputCrypto.java`.
* The renderer is the bundled `scrcpy-5.0` client. Its build now links `libm`
  on Linux; no other renderer changes were needed.
* `PeerTransport` (Iroh) builds unchanged on Linux and is linked into the helper.

### Security

The security model is unchanged from macOS:

* No input is sent until the phone proves the per-session key derived from the
  private pairing code.
* Every record is encrypted and authenticated under a strictly increasing
  directional sequence. Only the exact last ciphertext can be re-acknowledged.
* If Android replaces its BLE input service during a session (for example, an
  app update), the helper performs a bounded (4-second) rediscovery. It
  requires the same session nonce, re-proves the key and authenticates the
  phone's resume sequence before retransmitting anything. Otherwise the session
  ends. Update apps only while no mirror is running.
* Pairing codes are stored in owner-only files rather than a keyring.

The helper never calls BlueZ `Connect()` on the phone's dual-mode identity:
with the Classic video link up, BlueZ would also connect audio profiles. It
connects only the phone's LE advertising identity, which advertises this
pairing's discovery UUID, or uses GATT services that are already resolved.

## Android changes

The companion now supports multiple trusted computers:

* `ComputerPeers` stores up to two trusted computers, with no primary computer.
  The legacy `ready/peer` value is migrated into the list.
* The Shizuku Classic L2CAP listener accepts any trusted, bonded computer and
  reports which one connected. Its user-service version is bumped (5 → 6), so
  the daemon is replaced on update. Each session uses the connecting
  computer's own key for BLE input, Wi-Fi/ADB upgrades and the Iroh direct-IP
  endpoint.
* The background BLE service advertises one discovery UUID per computer.
  Current Mac and Linux apps name their key with a `keyId` in the BLE hello.
  Older Mac apps are matched by address, else alternate between the two keys.
* Clipboard text, media and handoff fan out to every connected computer.
  Interactive transfers (clipboard files, camera) follow the most recent
  computer that is still connected. Iroh side channels (clipboard files, app
  library, camera, bulk test) use the requesting computer's own key. Link
  sharing asks which computer to use when both are connected.
* A side-by-side test install: `./gradlew -PdroidmirrorApplicationId=app.droidmirror.bluetooth.linux
  "-PdroidmirrorAppLabel=DroidMirror (Linux test)" :assembleDebug`. Only one
  install can own the Classic L2CAP mirroring PSM at a time.
* Setup lists the trusted computers, each with a Remove action. Adding or
  removing a computer never interrupts an active mirror: the listener picks up
  the new list after the session ends.
* Test: `sh Native/test-computer-peers.sh`.

## Troubleshooting

* **"The phone did not accept the Bluetooth connection"**: check that this
  laptop is trusted in DroidMirror on the phone, the background bridge is
  enabled and Shizuku is running.
* **Pairing code is wrong**: show the code for *this* computer on the phone
  and save it again.
* **Phone is in use**: lock the phone, then mirror again.
* Logs: `~/.local/state/droidmirror/logs/`. Set `DROIDMIRROR_BLE_DEBUG=1` for
  per-write BLE traces.
