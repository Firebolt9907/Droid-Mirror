# Signed app updates and launch checks

The October 16, 2026 16:24:31 crash ended in dyld's `loadInsertedLibraries`, before
DroidMirror application startup, with `CODESIGNING / Invalid Page`. The unmapped
image length was 76,800 bytes, matching the host shim. The installed app and output
bundle had identical file hashes and passed deep/strict signature verification.
This is consistent with stale kernel signature state after an in-place executable
update, rather than evidence of a failed BLE handshake. It does not identify the
copying operation that caused the stale state.

Apple documents why updating signed code in place can crash despite valid bytes
on disk: [Updating Mac Software](https://developer.apple.com/documentation/security/updating-mac-software).

`build-app.sh` now builds into a fresh temporary bundle, signs there, checks the
real launcher, then atomically swaps the entire output app. The signing script
also copies to fresh files before signing and accepts an optional bundle path.
This keeps both compilation and signing away from previously mapped executable
inodes. The existing development identity remains unchanged for Keychain access.

Install with:

```sh
python3 tools/app-bundle.py install outputs/DroidMirror.app /Applications/DroidMirror.app
```

The installer creates fresh files beside the destination, verifies their signature,
and runs `--check-launch`. It uses macOS `renamex_np(RENAME_SWAP)` to exchange the
whole bundle, then checks the installed signature and launcher again. The previous
app remains at the printed hidden backup location. If either post-install check
fails, it swaps the old app back. It does not re-sign the installed app in place.

`--check-launch` runs through the native launcher and its injected host shim, then
loads the BLE library before returning. It exits before NSApplication startup,
pairing-key access, receiver startup, or phone connections. The installer requires
a signed Info.plist capability marker before invoking it, so an older binary
cannot accidentally treat the check as a normal GUI launch.

Validation:

```sh
python3 Native/test-bundle-publish.py
bash Native/test-host-isolation.sh
python3 tools/app-bundle.py check outputs/DroidMirror.app
```

The publication test holds the old executable open during replacement and checks
that its bytes/inode remain intact, that the new inode is published, that rollback
retains both bundles, and that a missing candidate does not alter the installation.
The actual signed app check tests the loader path implicated by this crash. It
separately does not establish Bluetooth connection reliability.

On host launch, an idle app also compares the background receiver's launch time
with the installed helper executable's modification time. A newer installed helper
gets a normal quit/relaunch, with a bounded 15-second wait and no forced kill.
This addresses LaunchServices reusing a receiver still mapped from a bundle moved
aside by an atomic update. Missing dates preserve the running helper. A running
renderer defers this refresh until a subsequent idle launch; it does not make
component replacement during active mirroring seamless. Receiver termination
stops its Bluetooth integration normally. `Native/test-host-isolation.sh` covers
the refresh policy and the active-renderer guard.
