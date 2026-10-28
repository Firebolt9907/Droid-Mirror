# DroidMirror Wear OS development builds

Built by Jeffrey Turkstra. These APKs have matching local debug signing certificates.

- Install `DroidMirror-WearOS-debug.apk` on the paired Wear OS watch.
- Update the phone in place with `DroidMirror-Phone-debug.apk` if its installed signing key matches.
- Build/update the matching Mac app from this source checkout for Mac battery reporting and Find my Mac.
- End active mirroring before updating the phone or Mac. Keep the phone installed to preserve pairing.
- Open the watch app once and allow notifications to enable the Galaxy Watch Now Bar privacy shortcut.

See [feature, build and validation notes](../../Native/WEAR-OS.md).

Phone/watch builds, watch lint, command-safety tests and Mac Bluetooth library compilation/linking passed. No connected watch/emulator was available; physical Now Bar and end-to-end device checks remain.
