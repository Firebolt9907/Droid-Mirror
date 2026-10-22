# DroidMirror

A native SwiftUI control center for scrcpy that makes Android mirroring on macOS feel closer to Apple's iPhone Mirroring.

## Guided first-time setup

Open DroidMirror on both devices. New Mac setups open the guide automatically;
you can reopen it from **DroidMirror → Set Up Phone…** or **Settings → Set up a phone…**.
The phone launcher walks through the same four steps and remembers where you stopped:

1. **Connect Bluetooth:** allow Nearby devices on Android, pair the phone and Mac
   in system Bluetooth settings, then select the matching device in each app.
2. **Prepare your phone:** follow the linked Shizuku setup guide, start Shizuku,
   and authorize DroidMirror. Shizuku may need starting again after a phone reboot.
3. **Pair DroidMirror:** tap **Show pairing code** on the phone, save that private
   code in the Mac guide, and **Enable background bridge** on the phone. This code
   is separate from the short system Bluetooth pairing code. Saving it to the Mac
   Keychain does not yet verify the connection.
4. **Try your first mirror:** lock the phone and press **Mirror my phone** on the Mac.
   The Mac marks onboarding complete only when mirroring starts successfully.

Notification forwarding and wireless ADB are optional. Android’s **Optional features
and recovery** includes those settings, display recovery and stopping the bridge.
Mac automatic connection attempts pause while its setup window is open. Switching
the selected Mac on Android requires stopping the existing bridge first, so setup
does not replace trust underneath an active mirror. Existing Mac setups retain
their configuration and can open the guide manually.

Validation: `bash Native/test-onboarding.sh` checks first-run migration, interrupted
setup, reopening, draft-code cleanup and renders all four Mac steps. The Android
activity is covered by the companion’s normal Java/Kotlin compilation; permission
prompts, Shizuku setup and pairing still require a physical-device walkthrough.

Direct Bluetooth Classic L2CAP is the default source transport: after one-time Android
setup (Shizuku authorization, a selected paired Mac and **Enable background bridge**),
press **Mirror on the Mac** to start privileged scrcpy capture. There is no
per-session Android screen-share prompt. The session starts entirely over Bluetooth,
then attempts to move video to an encrypted Iroh peer connection in the
background, preserving the exact same scrcpy window. Video tries direct LAN or Tailscale IP paths first,
then an already paired wireless ADB connection, then continues over Bluetooth.
Iroh relay servers and public discovery are disabled; Tailscale is not required.
Hybrid video stays HEVC
throughout and all input stays on BLE; direct ADB mode keeps its selected codec
and ADB input. Bluetooth starts at
approximately 320p, up to 15 fps and a 128 kbps HEVC target and maximum. Once Wi-Fi is confirmed,
resolution, frame rate and bitrate increase to the saved Wi-Fi/ADB picture targets
(1920 px longest edge, up to 60 fps and 12 Mbps by default). Every capture
resolution preserves the phone's exact aspect ratio; select **Native** in Picture
settings for full resolution when supported by the encoder. The Mac opens
fixed PSM `0xD001`; a Shizuku shell service owns Android’s authenticated Classic
L2CAP listener. This uses a hidden Android API and requires the matching Mac
and Android builds; it does not silently fall back to RFCOMM. Classic L2CAP carries only video, phone-to-Mac. All input, acknowledgements,
control replies, status events, heartbeats and session setup use BLE. Pair your Mac once
using **DroidMirror → Pair Bluetooth…** (or **Settings…**, ⌘,) and the code
from **Pair Mac (mirroring and notifications)** in the Android companion; no session
secret or control payload travels over Classic.

Mirroring refuses to start while the phone is awake and unlocked, showing **Phone is in use. Lock your phone, then try mirroring again.** This applies to Bluetooth and ADB; a sleeping phone or visible lock screen can still start mirroring. Bluetooth requires the matching updated Android companion.

Bluetooth remembers the phone selected in DroidMirror. With auto-start enabled,
launching the app starts that phone once; closing the mirror does not continually
reopen it. An unavailable saved pairing does not select another device.

**Automatic (Bluetooth → Wi-Fi)** is the default connection mode. On the first
launch after updating to this version, any previously saved transport selection
resets to Automatic. The remembered phone and other settings are retained;
subsequent launches respect any new transport choice you make.

The compiled test APK is `outputs/DroidMirror-Bluetooth-0.37-debug.apk`.
The phone Live Activity includes **Minimize**, which uses the paired BLE
connection to minimize the mirror window while streaming continues.
Android now uses one background service and one enable/stop setting for mirroring
readiness, the BLE ADB Bridge's encrypted ADB discovery, notification
forwarding, notification actions and replies. Authorizing Shizuku also grants
DroidMirror’s secure-settings permission for optional wireless ADB setup. Open **Notifications and wireless
ADB** in DroidMirror to enable it. Users of the separate bridge must stop it,
paste the shared pairing code once in **DroidMirror → Pair Bluetooth…** and
grant notification access to DroidMirror; see
[setup and migration](Native/ANDROID-BRIDGE.md).
Install the matching Mac and Android builds together. A phone power/screen-lock action ends the session, locks/restores the
phone through Shizuku, and shows a separate **phone was used** popup on Mac.
Session shutdown and control-channel disconnects cancel outstanding injected keyboard
presses, including letters and power/volume keys, so a lost release cannot keep Android's
screenshot or power-menu button combinations blocked after mirroring. This cleanup is
shared by Bluetooth and ADB. Regression coverage: `bash Native/test-injected-keys.sh`.
End-of-session audit notifications stay on the phone; the Mac does not post remote-use history banners. Phone notifications arrive live over encrypted Bluetooth, including during mirroring. Persistent/ongoing service notifications, group summaries, secret notifications, and the companion’s own notifications are excluded. Shell watchdog
recovery covers app death and stale stream leases; physical-device behavior still
needs validation. Mouse, keyboard, scrolling and navigation use the Bluetooth control channel through Shizuku. Audio remains available through ADB mode.
See [setup, behavior and validation limits](Native/CLASSIC-BLUETOOTH.md).

Clicking a forwarded notification brings the DroidMirror window forward. If the
phone is locked, its open action waits up to 30 seconds for you to unlock it.
The request is canceled if its notification changes, the authenticated Bluetooth
connection ends, or you click another notification. Replies and action buttons
continue to use Bluetooth directly. Run `bash Native/test-notification-open.sh`
to check the unlock and action queue policies.

In Mac **Settings → Notifications**, turn off individual phone apps to avoid
duplicate alerts from apps installed on both devices. Apps appear after an eligible
notification arrives. Choices persist across restarts and apply immediately,
including while mirroring. Disabling an app clears its mirrored Mac notifications
without dismissing anything on the phone. Re-enabling allows future notifications;
it does not replay cleared alerts. No Android update is required. Regression checks:
`bash Native/test-notification-apps.sh`.

For automatic video upgrades, install the current Mac build and Android 0.37.
Keep the existing Bluetooth pairing and Shizuku setup. The app first tries Iroh
using authenticated Bluetooth address hints plus local multicast discovery.
This includes direct encrypted Tailscale/VPN IP connections without Iroh relays. If that
fails, it tries already paired wireless ADB devices. Enable Wireless debugging and
pair the Mac once if you want this fallback. If neither path works, Bluetooth
video continues. Relays and public Iroh discovery are disabled on both devices.
Bluetooth still carries startup and input. Network loss recovers over Bluetooth
in the same window, then retries LAN followed by wireless ADB.
See [transport order and validation](Native/PEER-TRANSPORT.md).
The background bridge does not enable Wireless debugging automatically.

Share an HTTP or HTTPS link through **Share → DroidMirror** on either device to open
it in the other device’s default browser. This uses the paired Bluetooth connection
and works between mirror sessions. Both apps need the link-sharing update; the
phone must be Ready for Mac, and opening links on Android also requires authorized
Shizuku. Enable DroidMirror in the Mac’s Share menu if it is not listed. File sharing
through these share targets is not supported. See [link sharing](Native/LINK-SHARING.md).

Optional **Mirror clipboard over Bluetooth** in **Settings → Clipboard** or the visible DroidMirror menu adds two-way text and individual-file sync, including between mirror sessions. Files must be less than 5 MB (5,000,000 bytes). It uses
the existing encrypted pairing and requires Shizuku; enable it explicitly after
updating both apps. See [clipboard behavior, limits and validation](Native/CLIPBOARD-SYNC.md).

Optional **Settings → Media playback → Sync phone and Apple Music playback**
shows phone media in macOS Now Playing and Apple Music on Android, with playback
controls in both directions. Audio stays on its original device. Requires updated
apps, paired Bluetooth, Android notification access and Mac Music Automation
permission. See [media sync behavior and validation](Native/MEDIA-SYNC.md).

When the current phone task exposes a supported web URL, a **phone icon** appears
in the Mac menu bar. Click it to continue in your default browser. Google Docs
document intents and app-provided assist-content web URLs are supported, including
Chrome and Tangent Browser. Other tasks stay silent. The icon clears on
unsupported tasks or a stale Bluetooth connection.
This uses the paired encrypted background bridge and Shizuku, including between
mirror sessions, and requires matching updated Mac and Android builds. It does
not transfer browser login or document cursor/scroll state. See
[task continuation behavior and validation](Native/APP-TASKS.md).

With Android gesture navigation enabled, clicking the bottom pill once goes Home,
twice opens Recents, and three times sends a long Home press for Circle to Search
(on supported phones). The centered hit area is 20 Android dp high, capped by the
system navigation-bar height; dragging still sends a normal swipe. These shortcuts
are disabled with two-button or three-button navigation. Bluetooth requires the
updated companion APK. See [gesture-pill behavior and tests](Native/GESTURE-PILL.md).

The mirrored screen also shows a circular camera hole using Android's reported
cutout geometry. It follows video scaling and rotation, with no guessed camera
position on phones that report no cutout. Bluetooth requires companion 0.11 or
newer. See [camera-cutout geometry and validation](Native/CAMERA-CUTOUT.md).

## Background startup

In Mac **Settings → Background service**, enable **Start background service at login**.
This registers only the existing notifications/Bluetooth receiver with macOS Service
Management; the mirroring host and mirror window do not launch. If macOS requests
approval, use **Open Login Items Settings…** and allow DroidMirror. The switch reads
the system registration state, including changes made in System Settings. Stop
mirroring before changing this setting because unregistering a service can terminate
its running process. Startup occurs after user login, not before login or FileVault
unlock. No keep-alive restart loop is installed.

On Android, **Enable background bridge** already persists across reboots. The boot
receiver starts the connected-device foreground service after the first unlock;
stopping the bridge disables that restart. Bluetooth permissions must remain granted.
The listener waits for Bluetooth and authorized Shizuku without starting a mirror.
On non-rooted phones, Shizuku itself normally needs starting again after each reboot;
DroidMirror does not bypass that requirement. Manufacturer battery/auto-start
restrictions or force-stopping the app can prevent boot startup. Open DroidMirror
and enable the bridge again if necessary. Device reboot/login behavior still needs
physical validation.

## Phone hotspot

When the Mac has no network route, a hotspot icon appears in the menu bar.
Choose **Turn On Phone Hotspot** to request Internet tethering over the paired
Bluetooth bridge, then join the phone from the Mac Wi-Fi menu. Requires Android
11+, matching app builds and authorized Shizuku. The phone keeps its saved hotspot
name/password; save that network on the Mac once for macOS auto-join.
The icon also offers optional automatic activation after 15 seconds offline,
off by default, with one attempt per outage and a five-minute cooldown.
Phone/carrier restrictions can prevent activation. See
[hotspot behavior and validation](Native/PHONE-HOTSPOT.md).

## Experimental Wi-Fi Aware

Connection settings check access by attempting discovery through the native
private macOS API. The Catalyst experiment has been removed. Direct mirroring
remains blocked by authorization: this Mac rejects discovery, and a development
certificate with the Subscribe entitlement alone does not make the helper runnable.
See [the investigation and remaining integration work](Native/WIFI-AWARE.md).

## ADB mode highlights

ADB sessions now share [power-button recovery and the phone Live Activity](Native/ADB-SESSIONS.md).
Install companion 0.12 or newer for the Live Activity; Shizuku and Bluetooth readiness
are not required in ADB mode. Home-pill click detection uses a 180 ms window for
single, double and triple clicks, and Control-to-Home uses the same shorter delay.

- Automatic USB and wireless device discovery
- Guided Android 11+ wireless pairing
- One-click borderless mirror with 60 fps, zero video buffering, audio forwarding, and clipboard support
- Insert Mac emojis into the focused phone text field with **Control–Command–Space** or **Edit → Emoji & Symbols** (ADB and Bluetooth). Emoji insertion updates the phone clipboard and preserves the Mac clipboard.
- **Command–Backspace** deletes from the cursor to the start of the current line, using Shift–Home followed by Backspace.
- Optional device-screen-off, stay-awake, always-on-top, HEVC, and UHID keyboard modes
- Native Back, Home, Recents, volume, and power controls (Esc for Back, Control for Home, double-tap Control for App Switcher)
- Optional touch-style scrolling converts wheel/trackpad movement into real Android swipes, preserving overscroll and pull-to-refresh behavior
- Drag files onto the scrcpy window to send them to Android's Downloads folder

## Build and run

To build release versions of both apps and install them on this Mac and a connected,
authorized Android phone, run:

```sh
./build-release.sh
```

This uses JDK 21 by default (or `JAVA_HOME`), the Android SDK from `ANDROID_HOME`
(default `~/Library/Android/sdk`), and the dependencies listed below. The Mac build
uses Swift release optimization, optimized native helpers and the existing Mac
signing identity. Android uses `assembleRelease`, then APK alignment and signing
with the existing `~/.android/debug.keystore` to allow updates of the development
app without losing pairing or app data. This is a release build signed for local
device use. No new signing key is created.

Both builds finish before installation starts. Android updates with `adb install -r`;
the Mac installs at `/Applications/DroidMirror.app` using the checked, atomic
installer described below. Installations run sequentially; if either fails, the
script stops and reports the error. It never uninstalls the phone app to bypass a
signature mismatch. Reopen the apps after updating to use the new binaries.

```sh
./build-release.sh --device SERIAL        # Choose among connected phones
./build-release.sh --build-only           # Produce artifacts without installing
./build-release.sh --mac-destination "$HOME/Applications/DroidMirror.app"
```

The destination's parent directory must already exist and be writable. Artifacts
are `outputs/DroidMirror.app` and `outputs/DroidMirror-Bluetooth-release.apk`, with
an APK SHA-256 file alongside. For a custom Android signing key, set
`DROIDMIRROR_ANDROID_KEYSTORE`, `DROIDMIRROR_ANDROID_KEY_ALIAS`,
`DROIDMIRROR_ANDROID_STORE_PASSWORD`, and `DROIDMIRROR_ANDROID_KEY_PASSWORD`.
Passwords are passed to the signing tool through environment variables. To select
another Mac certificate, set `DROIDMIRROR_SIGNING_IDENTITY`.

Requirements: Rust 1.91+ (Cargo), macOS 14+, Xcode command-line tools, and the client dependencies (`brew install meson ninja pkg-config sdl3 ffmpeg libusb`). Building the customized Android server also requires JDK 17+ and Android SDK platform/build-tools 36 (`ANDROID_HOME`, default `~/Library/Android/sdk`). Bluetooth setup also requires the Android companion, Android NDK 28+ and the Rust
`aarch64-linux-android` target; see the linked guide.

```sh
chmod +x build-app.sh
./build-app.sh
```

The build now ends active mirrors, quits the Mac app and background helper normally,
updates the connected Android companion, and installs the entire signed Mac bundle
at `/Applications/DroidMirror.app`. Previously running Mac apps/helpers are reopened
from that installed bundle. No process is force-killed if graceful quit fails.

The verified, atomic bundle replacement includes the renderer, Bluetooth bridge and
notification helper, retains the previous installed bundle, and rolls back if the
final signature or launch check fails. A fresh build is also kept in
`outputs/DroidMirror.app`. Set `DROIDMIRROR_MAC_DESTINATION` to choose another installed
`.app` path, or `DROIDMIRROR_SKIP_MAC_INSTALL=1` to leave the installed Mac app alone.
`DROIDMIRROR_SKIP_ANDROID_INSTALL=1` skips the connected phone update. See
[signed-app update behavior](Native/MAC-APP-UPDATES.md).

For ADB mode, on Android enable **Developer options → USB debugging**. Connect once by USB and approve the computer. For wireless use, open the app's **Wireless connection** sheet and follow the pairing instructions.

Launch the app from Finder. Opening it through a sandboxed preview host can prevent adb from opening its local port. Touch-style scrolling is intercepted inside the scrcpy window and does not require Accessibility permission.

The mirror itself is scrcpy's hardware-accelerated window. DroidMirror deliberately uses the stable scrcpy input/video path instead of re-encoding or screen-capturing that window, preserving scrcpy's low latency.

## ADB scrcpy profile

The ADB launch profile uses a borderless 430×860 window, H.264 at 12 Mbps, 1920 px maximum size, 60 fps, zero video buffering, 30 ms audio buffering, SDK mouse/keyboard input, screen-off mirroring, stay-awake, and macOS Command remapped to Android Control when chorded with another key (standalone Command presses are not forwarded).

Wear OS companion: [privacy stop, battery glance and Find my Mac](Native/WEAR-OS.md).
