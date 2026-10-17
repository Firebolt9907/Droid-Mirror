# DroidMirror

A native SwiftUI control center for scrcpy that makes Android mirroring on macOS feel closer to Apple's iPhone Mirroring.

Direct Bluetooth Classic L2CAP is the default source transport: after one-time Android
setup (Shizuku authorization, a selected paired Mac and **Enable background bridge**),
press **Mirror on the Mac** to start privileged scrcpy capture. There is no
per-session Android screen-share prompt. The session starts entirely over Bluetooth,
then attempts to move video to an already paired wireless ADB connection in the
background, preserving the exact same scrcpy window. Hybrid video stays HEVC
throughout and all input stays on BLE; direct ADB mode keeps its selected codec
and ADB input. Bluetooth starts at
approximately 480p, up to 16 fps and a 256 kbps regular HEVC target. Once Wi-Fi is confirmed,
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

Bluetooth remembers the phone selected in DroidMirror. With auto-start enabled,
launching the app starts that phone once; closing the mirror does not continually
reopen it. An unavailable saved pairing does not select another device.

**Automatic (Bluetooth → Wi-Fi)** is the default connection mode. On the first
launch after updating to this version, any previously saved transport selection
resets to Automatic. The remembered phone and other settings are retained;
subsequent launches respect any new transport choice you make.

The compiled test APK is `outputs/DroidMirror-Bluetooth-0.20-debug.apk`.
Android now uses one background service and one enable/stop setting for mirroring
readiness, the BLE ADB Bridge's encrypted ADB discovery, notification
forwarding, notification actions and replies. Authorizing Shizuku also grants
DroidMirror’s secure-settings permission for automatic Wireless debugging. Open **Notifications and wireless
ADB** in DroidMirror to enable it. Users of the separate bridge must stop it,
paste the shared pairing code once in **DroidMirror → Pair Bluetooth…** and
grant notification access to DroidMirror; see
[setup and migration](Native/ANDROID-BRIDGE.md).
Install the matching Mac and Android builds together. A phone power/screen-lock action ends the session, locks/restores the
phone through Shizuku, and shows a separate **phone was used** popup on Mac.
End-of-session audit notifications are posted on phone and Mac. Shell watchdog
recovery covers app death and stale stream leases; physical-device behavior still
needs validation. Mouse, keyboard, scrolling and navigation use the Bluetooth control channel through Shizuku. Audio remains available through ADB mode.
See [setup, behavior and validation limits](Native/CLASSIC-BLUETOOTH.md).

For the automatic video upgrade, enable Android **Wireless debugging** and pair
this Mac once using DroidMirror's wireless connection sheet. Keep phone and Mac
on a network that permits wireless ADB. Bluetooth never waits for ADB at startup;
if it is unavailable, video stays on Bluetooth and retries in the background.
If ADB drops after an upgrade, a BLE signal restarts Bluetooth video in the same
window, restores the Bluetooth quality profile, and resumes wireless retries.
The saved BLE pairing key also authenticates the upgrade target, preventing a
different connected phone from taking over the window. See
[wireless handoff behavior and limitations](Native/WIRELESS-HANDOFF.md).

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
- Optional device-screen-off, stay-awake, always-on-top, HEVC, and UHID keyboard modes
- Native Back, Home, Recents, volume, and power controls (Esc for Back, Control for Home, double-tap Control for App Switcher)
- Optional touch-style scrolling converts wheel/trackpad movement into real Android swipes, preserving overscroll and pull-to-refresh behavior
- Drag files onto the scrcpy window to send them to Android's Downloads folder

## Build and run

Requirements: macOS 14+, Xcode command-line tools, and the client dependencies (`brew install meson ninja pkg-config sdl3 ffmpeg libusb`). Building the customized Android server also requires JDK 17+ and Android SDK platform/build-tools 36 (`ANDROID_HOME`, default `~/Library/Android/sdk`). Bluetooth setup also requires the Android companion; see the linked guide.

```sh
chmod +x build-app.sh
./build-app.sh
open outputs/DroidMirror.app
```

The build compiles and signs a fresh app bundle before replacing the output. To
update the installed app without overwriting signed executables in place, use:

```sh
python3 tools/app-bundle.py install outputs/DroidMirror.app /Applications/DroidMirror.app
```

This checks the signature and real launcher/library loading before and after an
atomic replacement, retains the previous installed bundle, and rolls back if the
final launch check fails. The check does not start mirroring or the notification
receiver. See [signed-app update behavior](Native/MAC-APP-UPDATES.md).

For ADB mode, on Android enable **Developer options → USB debugging**. Connect once by USB and approve the computer. For wireless use, open the app's **Wireless connection** sheet and follow the pairing instructions.

Launch the app from Finder. Opening it through a sandboxed preview host can prevent adb from opening its local port. Touch-style scrolling is intercepted inside the scrcpy window and does not require Accessibility permission.

The mirror itself is scrcpy's hardware-accelerated window. DroidMirror deliberately uses the stable scrcpy input/video path instead of re-encoding or screen-capturing that window, preserving scrcpy's low latency.

## ADB scrcpy profile

The ADB launch profile uses a borderless 430×860 window, H.264 at 12 Mbps, 1920 px maximum size, 60 fps, zero video buffering, 30 ms audio buffering, SDK mouse/keyboard input, screen-off mirroring, stay-awake, and macOS Command remapped to Android Control when chorded with another key (standalone Command presses are not forwarded).
