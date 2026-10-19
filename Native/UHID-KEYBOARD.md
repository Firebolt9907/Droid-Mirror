# Idle UHID keyboard and software keyboard visibility

The SDK typing path keeps an idle UHID keyboard open for the mirroring session.
Both the ADB controller and Bluetooth display guard use `IdleUhidKeyboard`.

On the Pixel 8 running Android 17, the previous device was already reported as
`KeyboardType: 2` (alphabetic), and `show_ime_with_hard_keyboard` was `0`, while
Gboard still displayed its software keyboard. Gboard's own diagnostics listed
`Android Mirror Virtual Keyboard` in `show_vk_devices_names`: a remembered
per-device override after choosing to show the software keyboard.

Use the stable name `Droidmirror Virtual Keyboard` and physical port
`droidmirror:keyboard`. The new name avoids inheriting the previous device's
Gboard override. The physical port prevents Android from merging it with other
zero-vendor/zero-product UHID devices. During diagnosis, a stock scrcpy keyboard
with an empty port was merged into the old keyboard (two EventHub IDs under one
Input Reader device), preserving its name. A probe with the distinct port was
correctly exposed as a separate alphabetic keyboard.

The Shizuku display guard service version must change when this code changes.
Its daemon survives APK updates; replacing the APK alone does not ensure the
next session executes the new keyboard registration code. Version 44 reloads
the corrected implementation on the next bind.

Run `bash Native/test-idle-uhid.sh` for packet identity, virtual bus, lifecycle,
failure rollback, and display-lease cleanup checks. Runtime verification must
also check Gboard visibility with a focused editor; alphabetic classification
alone is insufficient. Choosing to show the software keyboard again may save a
new Gboard override for the new name.

To undo an accidental "Show" selection, open Gboard's own settings, then
Physical keyboard → Show on-screen keyboard, and turn it off. Android's
similarly named system setting is separate from Gboard's saved override.

After reconnecting with service version 44, the Pixel reported the new name and
port as a separate alphabetic device, and Gboard's `pk_always_show_vk` was false.
Its full `InputView` and key-grid holders were `visibility=8` (gone). Only a
148-pixel `WidgetSoftKeyboardView` accessory/suggestion panel remained visible.
Gboard had `show_pk_toolbar=true`; this is independent of showing the full
software keyboard. Consequently `mInputShown=true` and `mImeWindowVis=3` alone
do not establish that the letter keyboard is visible. Inspect the view tree or
confirm visually before treating these flags as a suppression failure.
