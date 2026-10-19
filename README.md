# DroidMirror

Mirror and control your Android phone from your Mac with a native macOS app powered by scrcpy. Install DroidMirror on both devices, then use the setup guide to connect them.

For architecture, transport details, build options and validation notes, see the [technical README](README-TECHNICAL.md).

## What you need

- An Apple silicon Mac running macOS 14 or later. The current build scripts target Apple silicon.
- An Android phone running Android 8 or later. The default Android build targets ARM64 phones.
- Bluetooth enabled on both devices.
- [Shizuku](https://shizuku.rikka.app/guide/setup/) running on the phone for Bluetooth mirroring. Follow the setup guide linked inside the Android app; Shizuku may need starting again after a reboot.
- A USB cable for the build-and-install steps below. Once Bluetooth setup is complete, you can disconnect it.

## Install from source

Run these steps on the Mac where you want to use DroidMirror.

### 1. Prepare the build tools

Install Xcode command-line tools, Homebrew, Python 3, JDK 21 and Rust 1.91 or later. Install the native dependencies:

```sh
xcode-select --install
brew install meson ninja pkg-config sdl3 ffmpeg libusb
rustup target add aarch64-linux-android
```

<<<<<<< HEAD
`build-app.sh` quits the running Mac app before rebuilding. With an authorized Android phone connected, it also builds and installs the debug companion and automatically resumes its previously enabled bridge. Android builds require JDK 21 and the Android SDK (`ANDROID_HOME`, defaulting to `~/Library/Android/sdk`). Set `ANDROID_SERIAL` when multiple devices are connected, or `DROIDMIRROR_SKIP_ANDROID_INSTALL=1` for a Mac-only build. First-time setup and Shizuku authorization still happen in the Android app.

For ADB mode, on Android enable **Developer options → USB debugging**. Connect once by USB and approve the computer. For wireless use, open the app's **Wireless connection** sheet and follow the pairing instructions.
=======
Using Android Studio's SDK Manager, install Android SDK Platform 36, Build-Tools 36, Platform-Tools and NDK 28 or later. The scripts look for the SDK at `~/Library/Android/sdk`; set `ANDROID_HOME` if yours is elsewhere. They use JDK 21 by default; set `JAVA_HOME` to choose another installed JDK.
>>>>>>> c02160ea21eafda3c4ed266d80133223d2f9b0b3

Clone the repository and enter it:

```sh
git clone https://github.com/Firebolt9907/Droid-Mirror.git
cd Droid-Mirror
```

Configure signing before building:

- **Mac:** use `security find-identity -v -p codesigning` to find your signing certificate, then set `export DROIDMIRROR_SIGNING_IDENTITY="YOUR_CERTIFICATE_NAME_OR_HASH"`. The script's default certificate belongs to the original development environment. Keep the same signing identity across updates to preserve Keychain access.
- **Android:** the release installer uses an existing `~/.android/debug.keystore` by default. For a fresh development setup, run `(cd BluetoothCompanion && ./gradlew assembleDebug)` to build the debug app and create the standard debug keystore. Alternatively, configure your own key using the [technical README's signing options](README-TECHNICAL.md#build-and-run). Updates must use the same key as the installed phone app.

### 2. Connect your phone

On Android, enable **Developer options → USB debugging**. Connect the phone by USB, unlock it and approve the computer's debugging request. Confirm that it is authorized:

```sh
~/Library/Android/sdk/platform-tools/adb devices
```

Use your SDK's path if it differs. The phone should appear with status `device`, rather than `unauthorized`.

### 3. Build and install both apps

From the repository root, run:

```sh
./build-release.sh
```

This builds both apps, installs the Android APK on the connected phone and installs the Mac app at `/Applications/DroidMirror.app`. The Android release build uses the signing key configured above; by default, that is the local debug key.

Before installing, the script quits the running Mac app to end active mirror sessions gracefully. After installing both apps, it automatically requests Android background bridge startup using your saved setup. If setup or permissions are missing, it reports that the bridge needs attention; open DroidMirror on Android and enable the background bridge once. Reopen the Mac app after the update.

If more than one phone is connected, choose one with `./build-release.sh --device SERIAL`, using its serial from `adb devices`. If `/Applications` is not writable, create `~/Applications` and run:

```sh
mkdir -p "$HOME/Applications"
./build-release.sh --mac-destination "$HOME/Applications/DroidMirror.app"
```

Open DroidMirror from Finder on the Mac and from the app launcher on Android.

### Already have matching builds?

If you already have a built checkout, you can install its artifacts without rebuilding:

```sh
python3 tools/app-bundle.py install outputs/DroidMirror.app /Applications/DroidMirror.app
~/Library/Android/sdk/platform-tools/adb install -r outputs/DroidMirror-Bluetooth-release.apk
```

The Mac installer verifies the bundle and replaces it atomically. Keep the matching Mac and Android builds together. To produce these artifacts without installing them, use `./build-release.sh --build-only`.

## Connect the apps for the first time

The Mac opens its setup guide automatically. Reopen it anytime from **DroidMirror → Set Up Phone…** or **Settings → Set up a phone…**. Follow the corresponding guide on Android:

1. **Connect Bluetooth.** Allow Android's Nearby devices permission and the Mac's Bluetooth permission. Pair the phone and Mac in system Bluetooth settings, then select the matching device in each app.
2. **Prepare your phone.** Install and start Shizuku using the guide linked in DroidMirror, then authorize DroidMirror to use it.
3. **Pair DroidMirror.** Tap **Show pairing code** on the phone and save that code in the Mac guide. This private code is separate from the system Bluetooth pairing code. On Android, choose **Enable background bridge**.
4. **Start mirroring.** Lock the phone, then press **Mirror my phone** on the Mac. Setup finishes when the first mirror starts successfully. You can now disconnect the USB cable.

Leave the connection mode at **Automatic (Bluetooth → Wi-Fi)** to start over Bluetooth and let video upgrade to a direct network connection when available. Tailscale is optional. Notification forwarding and wireless ADB are optional too; neither is required to complete Bluetooth setup.

For USB/ADB mirroring instead, keep USB debugging enabled, connect and authorize the phone, and select ADB mode in DroidMirror. Shizuku and Bluetooth readiness are not required for ADB mode. Wireless ADB pairing is available through the Mac app's **Wireless connection** sheet on Android 11 or later.

## Updating

End any active mirror session before installing either app. Replacing the Android app or restarting its Bluetooth service during mirroring can disconnect the session.

Install matching builds on both devices using the steps above, then reopen both apps. Keep the same signing keys and use Android's update installation (`adb install -r`) to retain app data and pairing. If Android reports a signature mismatch, use the original signing key; the installer does not uninstall the app to bypass it.

## If setup gets stuck

- **Phone is in use:** lock the phone, then start mirroring again.
- **Bluetooth mirroring is unavailable:** check Bluetooth permissions and the selected devices, confirm Shizuku is running and authorized, and enable the Android background bridge.
- **After a phone reboot:** unlock the phone once and restart Shizuku if needed. If the bridge has not resumed, open DroidMirror and enable it again.
- **A session ended during an update:** finish updating both apps, reopen them and start a new mirror session.
- **ADB says `unauthorized`:** unlock the phone and approve the debugging prompt.
- **The build cannot find a signing certificate or keystore:** complete the signing configuration above. See [build and signing details](README-TECHNICAL.md#build-and-run) for custom keys and paths.

See the [technical README](README-TECHNICAL.md) for optional features, detailed behavior and developer documentation.
