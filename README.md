# DroidMirror

A native SwiftUI control center for scrcpy that makes Android mirroring on macOS feel closer to Apple's iPhone Mirroring.

Bluetooth Classic RFCOMM is the default source transport: after one-time Android
setup (Shizuku authorization, a selected paired Mac and **Enable Mac connections**),
press **Mirror on the Mac** to start privileged scrcpy capture. There is no
per-session Android screen-share prompt and no ADB/LAN transport. The profile
is approximately 480p, up to 30 fps and a 1 Mbps H.264 target.

The compiled test APK is `outputs/DroidMirror-Bluetooth-0.4-debug.apk`.
Rebuild the Mac app for the matching event transport; checked-in Mac binaries are
unchanged. A phone power/screen-lock action ends the session, locks/restores the
phone through Shizuku, and shows a separate **phone was used** popup on Mac.
End-of-session audit notifications are posted on phone and Mac. Shell watchdog
recovery covers app death and stale stream leases; physical-device behavior still
needs validation. Audio and remote input remain available through ADB mode.
See [setup, behavior and validation limits](Native/CLASSIC-BLUETOOTH.md).

## ADB mode highlights

- Automatic USB and wireless device discovery
- Guided Android 11+ wireless pairing
- One-click borderless mirror with 60 fps, zero video buffering, audio forwarding, and clipboard support
- Optional device-screen-off, stay-awake, always-on-top, HEVC, and UHID keyboard modes
- Native Back, Home, Recents, volume, and power controls (Esc for Back, Control for Home, double-tap Control for App Switcher)
- Optional touch-style scrolling converts wheel/trackpad movement into real Android swipes, preserving overscroll and pull-to-refresh behavior
- Drag files onto the scrcpy window to send them to Android's Downloads folder

## Build and run

Requirements: macOS 14+, Xcode command-line tools, and the client dependencies (`brew install meson ninja pkg-config sdl3 ffmpeg libusb`). Bluetooth setup also requires the Android companion; see the linked guide.

```sh
chmod +x build-app.sh
./build-app.sh
open outputs/DroidMirror.app
```

For ADB mode, on Android enable **Developer options → USB debugging**. Connect once by USB and approve the computer. For wireless use, open the app's **Wireless connection** sheet and follow the pairing instructions.

Launch the app from Finder. Opening it through a sandboxed preview host can prevent adb from opening its local port. Touch-style scrolling is intercepted inside the scrcpy window and does not require Accessibility permission.

The mirror itself is scrcpy's hardware-accelerated window. DroidMirror deliberately uses the stable scrcpy input/video path instead of re-encoding or screen-capturing that window, preserving scrcpy's low latency.

## ADB scrcpy profile

The ADB launch profile uses a borderless 430×860 window, H.264 at 12 Mbps, 1920 px maximum size, 60 fps, zero video buffering, 30 ms audio buffering, SDK mouse/keyboard input, screen-off mirroring, stay-awake, and macOS Command remapped to Android Control when chorded with another key (standalone Command presses are not forwarded).
