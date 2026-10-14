# Release forwarded keys

The client releases forwarded keys when the mirror loses focus, is hidden or
minimized, and before a normal shutdown. SDK mode tracks Android keycodes that
were successfully queued and emits key-ups directly, so text-mode filtering
cannot suppress cleanup. HID mode releases tracked scancodes with cleared
modifiers. Tracking happens after the Command/Control remapping. Injected
shortcut keys (including Power and Volume) are released too.

Keyboard transitions are non-droppable under queue backpressure. Shutdown waits
up to 300 ms for pending control messages, including the current send, before
closing sockets. Cocoa terminate actions now request an SDL quit; the host gives
scrcpy a graceful SIGINT opportunity before falling back to termination.

Abrupt transport loss or forcibly killing the process can still prevent delivery
of a release. This change prevents future stale key state; it cannot guarantee
recovery of keys left pressed by an older client.

Linux regression checks after configuring a scrcpy Meson build:

```sh
bash Native/run-key-release-tests.sh /path/to/meson/build
meson test -C /path/to/meson/build --print-errorlogs
```

Checks cover SDK/HID focus loss, normal releases, cleanup retries, text-mode
filtering, Power shortcut release, repeated cleanup, ordered transport delivery,
and bounded drain timeouts. The simulated failed enqueue intentionally logs one
release warning.

On macOS, rebuild the customized scrcpy client, the keyboard passthrough shim
and host shim, and sign the app using the existing build/signing workflow.
Phone verification: start a stream, hold Shift while switching windows or
invoking a Mac screenshot shortcut, then close via the toolbar and Cmd+Q in
separate runs. Verify both Power+Volume Down screenshots and Power+Volume Up
power menu on the Pixel after each run. Repeat with SDK and UHID keyboards.
