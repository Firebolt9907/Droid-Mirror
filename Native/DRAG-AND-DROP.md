# Drag and drop

Drag one regular file from Finder onto the active mirror. An accent border and
“Drop to save in phone Downloads” label indicate acceptance. The label reports
preparation, acknowledged byte progress, completion or failure. Direct ADB shows
an indeterminate sending state until `adb push` exits. Completion labels disappear
after six seconds. Directories, symbolic links, multi-file batches and inactive
connection surfaces are rejected. Phone-to-Mac dragging is not implemented;
existing phone-to-Mac clipboard file/image sync remains available.

## Bridge transport

Enable clipboard mirroring, use an updated companion on Android 10+, and keep the
phone unlocked. Drops reuse the clipboard file preparation handshake and bounded
snapshot reader (strictly less than 5,000,000 bytes). They do not replace either
clipboard. A clipboard change, phone lock, disconnect, disabled sync or timeout
cancels a pending transfer under the existing clipboard safety rules. Only one
clipboard/drop file operation can run at a time.

The authenticated `ready` capability `clipboardDownloads: 1` gates this feature.
`clipboardFileBegin` gains an optional `destination: "downloads"`; absence means
normal clipboard delivery. Unknown destinations are rejected. No message IDs,
new radio channels or relaxed authentication/sequence checks are introduced.
Metadata flows unchanged through the existing Iroh/direct-IP versus LE L2CAP
race, including digest verification, bounded retry and final apply ACK handling.
BLE bulk continues if the fast IP lane fails; there is no new GATT data fallback.
An old companion cannot advertise the capability and is refused on the Mac.

The companion writes complete bytes into a pending MediaStore Downloads entry,
then publishes it before acknowledging success. MediaStore handles name collisions;
failed writes remove the pending entry. A lost final ACK followed by replay can
save another copy. No storage permission or Shizuku service
code change is needed. Existing clipboard token, size, name and offset checks still
apply. The receiver's existing progress activity and Cancel action remain in use.

The viewer forwards paths to the existing background receiver with local
`app.droidmirror.fileDrop` notifications. `app.droidmirror.fileDropStatus` returns
UI progress. These local notifications are not transport authorization: the receiver
still requires an authenticated, ready, opted-in clipboard subscription and the
Downloads capability. A missing receiver produces a bounded UI failure message.

## Direct ADB and APKs

Direct ADB sessions use the selected device serial and argument-array `adb push`
to `/sdcard/Download/`. They have no clipboard size limit. Ordinary drops still save APKs in Downloads. The explicit Mac install action sends
`clipboardFileBegin.destination = "install"` when authenticated `ready.apkInstall = 1`.
APKs must be smaller than 256 MiB; clipboard/Downloads remain below 5 MB. Installs
use one transport lane, a private Android cache file, SHA-256 verification and a
separate non-daemon Shizuku shell service (`cmd package install -r -S`). The final
secure `clipboardApkInstallResult` reports `id`, `ok`, `message`, and `package`. The companion
refuses its own package; use the normal companion update path. BLE-only transfers
of large APKs can be slow. SDL's normal APK auto-install/drop
handler is replaced on this view to avoid duplicate transfers.

## Validation

- `bash Native/test-file-drop.sh`: real named pasteboard, destination registration,
  regular-file acceptance, highlight, inactive-session and batch rejection.
- `bash Native/test-clipboard-sync.sh`: existing Swift/JVM clipboard suite plus
  Downloads capability gating, bounded single operation, destination metadata,
  final completion, unchanged Mac pasteboard and disconnect cancellation; JVM
  Downloads sink verifies APK bytes, unchanged phone clipboard and bad-offset /
  unknown-destination rejection. The JVM sink is simulated; production MediaStore
  is checked by Android compilation.
- Compile only: Android `compileDebugKotlin compileDebugJavaWithJavac`; Mac BLE
  source-list `swiftc -typecheck` and native chrome `clang -fsyntax-only`.

Hardware checks still needed: actual Finder drag dispatch through SDL, Iroh winner
and BLE-only completion, Downloads contents/collision behavior, phone lock and
notification Cancel, lost final ACK/retry, direct ADB with Unicode/spaces, large
ADB files, and opening the saved APK. End active mirror sessions gracefully before
updating either app; no install or service restart is part of these tests.
