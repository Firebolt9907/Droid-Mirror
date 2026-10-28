# Detecting haptic requests while muting the phone

Investigation by Jeffrey Turkstra, 2026-10-28.

## Finding

A rootless proof of concept works on the connected Pixel 8, Android 17 preview
`google/shiba/shiba:17/CP3A.261005.005/16271449:user/release-keys`.
Request-entry trace markers remain observable when the normal vibration-off
setting prevents motor activation. This can drive a Mac tick without waiting
for a physical-vibrator state change.

The original experiment below ran under ADB shell. The implementation was then
installed and validated in a live Shizuku mirror session on this Pixel. This does
not establish coverage of every app/system request or support on other devices.

## Installed validation

On 2026-10-28, `Native/test-silent-haptics-device.sh` passed using the built APK:
six requests were detected with no motor onsets, with successful normal,
SIGKILL, and trace-failure restoration. The Android app was installed at 10:09.
An active mirror replaced old display-guard PID 19163 with PID 13502. The new
daemon logged `Request tracing and phone suppression active (display guard v72)`;
`vibrate_on` was `0` and `tracing_on` was `1` during the live session.

After a normal host quit (which also prevented automatic mirror reconnect), the
phone's original absent `vibrate_on` setting and `tracing_on = 0` were verified.
The independent watchdog logged lease release at 10:12:15. The Mac host was left
closed after validation; the existing background notification helper was retained.

## Implemented behavior

Display guard v72 adds `SilentHaptics` and `HapticTraceParser`. Silent mode starts
only after capture is armed and an authenticated Bluetooth forwarding subscriber
is available. Setup and restoration run separately from mirror heartbeats. The
reader opens the trace pipe read-only/nonblocking, filters system-server request
entries, suppresses nested duplicates and stale events, and reports stream loss.
It refuses an existing tracing session and releases the mute if tracing stops or
the trace category configuration changes.

`HapticVibrationRecovery` saves the original setting in device-protected private
preferences before suppression. Recovery permission must be granted before
silent mode can start. A separate shell watchdog restores the setting on parent
pipe EOF or a five-second heartbeat timeout. The app also retries restoration on
session close, service startup, and locked/unlocked boot. New nonzero user edits
are preserved. Failed startup retains normal phone vibration/state-listener
forwarding. Accessibility/privileged exceptions still apply.

Verification commands:

```sh
bash Native/test-silent-haptics.sh
# After :assembleDebug, end mirroring and connect an authorized phone:
bash Native/test-silent-haptics-device.sh
```

Host checks cover service-only trace filtering, nesting, concurrent requests,
stale records, trace loss, absent/disabled settings, durable recovery retry, and
the actual watchdog shell script's stop/EOF/timeout/trace-ownership behavior.
The device test exercises six suppressed requests, motor-state silence, normal
restoration, abrupt parent death, and trace failure using production classes.

## Experiments

A temporary `app_process` helper invoked the actual `IVibratorManagerService`
Binder proxy and registered the production `HapticListener`, plus AppOps
started/noted observers. It issued three predefined vibration requests and three
UI haptic-feedback requests in each setting state. The UI requests used the
device's actual eight-argument `performHapticFeedback` Binder signature.

With vibration enabled:

- Six request-entry markers and six vibrator onsets were observed.
- Six AppOps-start callbacks were observed.
- HAL activation markers were present.

With `settings put system vibrate_on 0`:

- `dumpsys vibrator_manager` confirmed `vibrateOn = false`.
- All six request-entry markers were still observed.
- No vibrator onsets, AppOps-start callbacks, or HAL activation markers were
  observed in the test window.
- Device-local marker-to-reader delays were 0.123–1.725 ms, median 0.636 ms.
  This small sample excludes Bluetooth transmission and Mac playback latency.

A separate test temporarily set only `com.android.shell`'s VIBRATE app-op to
`ignore`. Request markers survived, but state/AppOps callbacks did not. AppOps
observers therefore do not replace request tracing for blocked requests.

## Trace access

`atrace --stream vibrator` fails with `error opening trace_pipe: Permission
denied (13)`. The implementation opens the pipe using `O_RDWR`, while the device
permits shell read access through the `readtracefs` group.

The working path is:

```sh
adb shell atrace --async_start vibrator
# A shell Java process reads this file using FileReader / O_RDONLY:
# /sys/kernel/tracing/trace_pipe
adb shell atrace --async_stop
```

The Java reader filters system-server `tracing_mark_write` begin markers named
`vibrate` and `performHapticFeedback`. Other entry points and internal system
calls require coverage checks. Process filtering and nesting/deduplication matter:
the same trace name may also be emitted by an app-side wrapper.
The existing display-guard and Shizuku-server processes both have shell UID 2000
and supplementary group 3012 (`readtracefs`), matching the successful probe's
trace-reading group. Reading from a freshly deployed service still needs testing.

## Implementation implications

Moderate work, rather than a settings-only toggle:

1. Add a session-scoped read-only request-trace listener in the Shizuku service;
   verify access from that service, not just the ADB probe.
2. Establish a healthy listener before saving and disabling `vibrate_on`.
3. Forward request events through the existing authenticated haptic event path,
   with filtering and duplicate suppression instead of the motor-state listener.
4. Restore the exact previous setting on normal stop, app death, transport loss,
   trace failure, and startup recovery. The original setting can be absent, so
   restoration must support deleting it, rather than always writing `1`.
5. Coordinate with system tracing/Perfetto. The experiment changes global atrace
   state and consumes a shared trace pipe; a feature must not disrupt another
   tracing session or silently leave vibration disabled when trace access fails.
6. Validate real keyboard, navigation, notifications, bypass cases, and idle CPU
   cost before describing this as complete Mac-only haptics.

Android's vibration-off setting has accessibility and privileged bypass
exceptions. It is not a hardware-level guarantee that every motor use is muted.
Apps can also suppress requests themselves before reaching the service; tracing
cannot recover requests that were never sent.

## Restoration

The original `vibrate_on` value was absent (`settings get` returned `null`). It
was restored by deleting the temporary override. The shell VIBRATE app-op was
restored to `allow`, and `tracing_on` was verified as `0`. The temporary DEX was
removed from `/data/local/tmp`. No app components were replaced by this experiment.

## Primary references

- [VibratorManagerService request-entry traces and policy checks](https://android.googlesource.com/platform/frameworks/base/+/refs/heads/main/services/core/java/com/android/server/vibrator/VibratorManagerService.java)
- [VibrationSettings policy and accessibility exemption](https://android.googlesource.com/platform/frameworks/base/+/e9050bbcb7ee43cc6870c054b884a0bace2f156e/services/core/java/com/android/server/vibrator/VibrationSettings.java)
- [atrace streamTrace opens the pipe with O_RDWR](https://android.googlesource.com/platform/frameworks/native/+/766c08dccf41e068819e0d48892106f3d125f5d6/cmds/atrace/atrace.cpp)

Those source revisions explain the mechanisms; the measurements above come from
the connected Android 17 device, whose hidden API signatures differ from some
published source revisions. Raw results and the temporary probe source were kept
under `/tmp/droidmirror-silent-haptics` for this session.

## Recovery latency follow-up

The user reported roughly ten seconds of missing Gboard feedback after local
takeover. A setting-only probe on the previous build restored `vibrate_on` in
about 1.3 seconds; that did not establish when Gboard feedback actually returned.

Recovery now signals the independent watchdog at session end, before queued
capture/display/trace cleanup. The app also starts setting recovery immediately
on local takeover or close and retains the durable snapshot until serialized
startup/close has finished. This covers startup completing after the early
restoration attempt.

On this device, app-side `ContentResolver.delete` fails for the platform-defined
setting even with `WRITE_SECURE_SETTINGS`. App recovery now writes a null value
to restore the default; the shell watchdog deletes the empty row as well as a
temporary zero override. Numeric settings and newer nonzero edits remain intact.

Validation on Pixel 8:

- Production device harness detected six requests while the motor stayed off.
- After `requestRestore()`, real framework `KEYBOARD_TAP` motor events resumed in
  386 ms, before calling `close()` at all. This tests motor recovery independently
  of slow teardown, but does not test Gboard's own request generation.
- Host parser, durable recovery, and production watchdog tests passed; device
  normal-stop, SIGKILL, and trace-failure recovery tests passed.
- Installed service v76 replaced the previous daemon (PID 26688, previously
  23290). Runtime logs identified the v76 request-tracing implementation.
- Power-button local takeover logged cause 3 and restored the absent setting in
  452 ms from the ADB key command. The temporary row was absent, tracing was off,
  and this run logged no recovery exception. Shell cleanup reported 313 ms.

Actual Gboard feedback latency still requires the user's immediate typing test;
these measurements do not establish that its reported ten-second delay is gone.
