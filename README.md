# DroidMirror

Mirror and control your Android phone from your Mac. Install DroidMirror on both devices, complete the one-time setup, then start mirroring from your Mac.

## What you need

- **Mac:** an Apple silicon Mac (M1 or newer) running macOS 14 Sonoma or later. The current builds target Apple silicon.
- **Phone:** an ARM64 Android phone running Android 8 or later. Android 11 or later makes Shizuku setup easier because it supports wireless debugging.
- **Bluetooth:** enabled on both devices, with the phone near your Mac.
- **Shizuku:** a free Android app that gives DroidMirror the access it needs to mirror and control your phone. You'll set it up below.

You don't need to build the app or install developer tools to use the release downloads. On Android 11 or later, Shizuku can usually be started without a USB cable; older Android versions may require a computer and USB setup.

## 1. Download DroidMirror

Open **[GitHub Releases](https://github.com/Firebolt9907/Droid-Mirror/releases)** and choose the latest release. Expand **Assets** if the downloads aren't visible.

Download both apps **from the same release**:

- On your **Mac**, download the Mac app package.
- On your **phone**, download the Android file ending in **`.apk`**. You can open the releases link directly in your phone's browser.

The **Source code (zip)** and **Source code (tar.gz)** links are for developers; choose the app downloads instead. If a release doesn't include both apps, use a release that does.

## 2. Install the Mac app

1. Open the downloaded Mac package. If it's a ZIP, double-click it to extract it. If it's a disk image (`.dmg`), double-click it to open it.
2. Drag **DroidMirror** into your **Applications** folder.
3. Open **Applications → DroidMirror**.
4. Allow Bluetooth access when macOS asks.

If macOS blocks the app because it can't verify the developer, check that you downloaded it from this repository's releases. You may need to allow it in **System Settings → Privacy & Security**, then open it again.

The setup guide opens automatically on first launch. You can reopen it from **DroidMirror → Set Up Phone…** or **Settings → Set up a phone…**.

## 3. Install the Android app

1. Open the downloaded **`.apk`** on your phone, either from your browser's downloads or the **Downloads** folder in your file manager.
2. If Android asks, allow that browser or file manager to **install unknown apps**. This permission lets it install the APK you downloaded outside the Play Store.
3. Tap **Install**, then open **DroidMirror**.
4. Allow **Nearby devices** and any Bluetooth permission requested by the setup guide.

You can turn off the browser or file manager's permission to install unknown apps after installation.

## 4. Connect your phone and Mac

Keep DroidMirror open on both devices and follow their setup guides.

### Connect Bluetooth

1. Open Bluetooth settings on both devices: **System Settings → Bluetooth** on Mac and **Settings → Bluetooth** on Android (the name may vary by phone).
2. Pair the phone and Mac. Confirm the matching system pairing code if asked.
3. Return to DroidMirror on each device. Select your **phone on the Mac** and your **Mac on the phone**.

### Set up Shizuku on your phone

1. In DroidMirror on Android, open **Prepare your phone** and tap **Get Shizuku / setup guide**. You can also use the [official Shizuku setup guide](https://shizuku.rikka.app/guide/setup/).
2. Install Shizuku and follow its instructions to start it. On Android 11 or later, use its wireless debugging method if available. The guide explains how to enable Developer options and Wireless debugging.
3. Once Shizuku says it is running, return to DroidMirror and authorize it to use Shizuku when prompted.

Shizuku normally needs to be started again after restarting a non-rooted phone.

### Pair the two DroidMirror apps

1. Select the phone in the Mac's DroidMirror setup guide and choose **Pair with QR code…**. On Android, select that Mac and tap **Scan Mac QR code**.
2. Wait for both devices to confirm the key was saved. This transfers the existing private key without changing it. With older versions, tap **Show pairing code** on Android and enter and save it on the Mac instead. This private code is separate from the system Bluetooth pairing code; keep it private.
3. On the phone, tap **Enable background bridge**. This keeps the phone ready for connections from your Mac.

Automatic BLE discovery is restricted to your DroidMirror pairing. Use matching,
updated Mac and Android apps; older generic BLE advertisements are ignored. Stop
any active mirror before updating, then restart the phone's background bridge.

### Start your first mirror

1. Lock your phone using its power button. DroidMirror won't start a mirror while the phone is awake and unlocked.
2. On the Mac, press **Mirror my phone**.
3. Wait for your phone's screen to appear, then use your Mac's mouse and keyboard to control it.

Leave the connection mode at **Automatic (USB / Wi-Fi / Bluetooth)**. Mirroring starts over Bluetooth and prefers an approved USB accessory connection for video when a supported phone is plugged in, without USB debugging or ADB access. Otherwise it can switch video to a faster direct network connection when available. USB video adds no playback buffer; encoding, decoding and display still take time. Keeping both devices on the same Wi-Fi network can help. Tailscale isn't required.

## Everyday use

Keep Bluetooth enabled and the Android background bridge running. Lock your phone, open DroidMirror on the Mac, and start mirroring. You don't need to enter the pairing code each time.

After restarting your phone, unlock it once and start Shizuku again if needed. If DroidMirror isn't ready, open it on the phone and enable the background bridge again.

Notification forwarding and other extras are optional. You can finish the first mirror before setting them up.

For a black phone screen with a grey mirroring message, open **Optional features and recovery** on Android and enable **Black out phone with mirroring message (optional)**. It is off by default, requires Android 12 or later and Shizuku, and takes effect on your next mirror session. It replaces panel-off mode while enabled. Press the power button to end mirroring and return to the phone’s lock screen. The display stays powered on. Physical touchscreen input is blocked while Mac controls remain available. See [blackout overlay details and validation](Native/BLACKOUT-OVERLAY.md).

### Phone audio over Wi-Fi

In Automatic mode, once video connects over Wi-Fi, playing media on a phone running Android 12 or later shows **Play phone audio over Wi-Fi** below the mirror when the phone is not using Bluetooth audio. Click it to listen on your Mac; click **Stop phone audio** to return sound to the phone. The stream stops when media pauses, Bluetooth audio connects, or Wi-Fi disconnects. Some apps restrict audio capture.

The phone speakers are silenced while forwarding. The original media volume and mute state are restored when forwarding or the mirror session ends. Other volume categories are unchanged.

Audio uses a continuous playback buffer with a small Wi-Fi jitter reserve to avoid stuttering. Wi-Fi does not guarantee exact lip sync. The USB / wireless ADB mode retains its existing audio behavior.

## Updating

1. **End your mirror session and quit DroidMirror on the Mac before updating either app.** Updating the phone app during mirroring can disconnect the session.
2. Download both apps from the same new [GitHub release](https://github.com/Firebolt9907/Droid-Mirror/releases).
3. Replace DroidMirror in your Mac's Applications folder with the new app.
4. Open the new Android APK and choose **Update**. Keep the existing app installed so its settings and pairing can be retained.
5. Reopen both apps. Check that Shizuku is running and the Android background bridge is enabled, then start a new mirror session.

If Android says the update conflicts with the installed app, the apps may use different signing keys. Use an update from the same source as your installed version. Uninstalling the phone app removes its saved setup and requires pairing again.

## If something doesn't work

- **“Phone is in use”:** lock the phone, then try mirroring again.
- **The phone or Mac doesn't appear:** check that Bluetooth is on, the devices are nearby and paired in system settings, and Bluetooth/Nearby devices permissions are allowed. Check the device selected in each DroidMirror app.
- **Bluetooth mirroring isn't ready:** open Shizuku and confirm it's running, check that DroidMirror is authorized, then open DroidMirror on the phone and enable the background bridge.
- **It stopped working after a phone restart:** unlock the phone once, restart Shizuku, and check the background bridge.
- **A session ended while updating:** finish updating both apps, reopen them, and start a new session.
- **Video is slow:** check that both devices are on the same Wi-Fi network and leave the connection mode on Automatic. Bluetooth-only video uses lower quality.

For source builds, connection details, and advanced features, see the [technical README](README-TECHNICAL.md).

### Mac left-behind alerts (experimental)

On Android, open **Notifications and wireless ADB (optional)** and enable **Mac left-behind alerts (experimental)**. Keep the background bridge enabled and DroidMirror running on your paired Mac. The phone can notify you after at least 45 seconds of Bluetooth separation when recent movement is detected. Allow DroidMirror notifications. Mac sleep or disabling Mac Bluetooth can cause false alerts; closed-lid reliability needs device testing. See [behavior and limitations](Native/LEFT-BEHIND.md).
