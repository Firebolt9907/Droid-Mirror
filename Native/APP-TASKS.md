# Android 17 App Tasks / Continue On investigation

Actual Gmail draft handoff payload extraction was investigated separately in
[HANDOFF-PAYLOAD.md](HANDOFF-PAYLOAD.md). The tested secure shell-peer transport
failed attestation; no draft fallback URL was retrieved. Gmail's handoff
eligibility should not be presented as working web continuation.

## Implemented task URL continuation

The Android background bridge now starts a separate Shizuku `TaskUrlBridgeService`
only while an authenticated Mac subscribes using `taskSubscribe`. It reads the
top task on the phone's default display using structured `getTasks` every two
seconds. It requests `AssistContent` for that task, with screenshots and view
structure capture disabled, and accepts only a validated HTTP/HTTPS web URI
explicitly supplied by the app. This reads current content rather than assuming
the launch intent tracks browser navigation. Chrome and Tangent Browser both
returned current-page URLs in live tests; Docs supplied its own document URL,
including a document-tab parameter. Other cooperating apps work without a new
package-specific rule. Unsupported tasks and lookup failures send a clear event.
No URLs are persisted or logged.

If assist content has no usable URL, the tested Google Docs
`content://uniqueId/DOCUMENT_ID` conversion remains available. Generic HTTP/HTTPS
launch URLs are no longer a fallback: a browser can retain the initial URL after
navigation or a switch to private content. Each assist request has its own
receiver and a 1.5-second timeout; replies arriving after the deadline are
discarded. The top task ID and activity are checked again before publishing a
result, so switching apps during a lookup cannot publish the previous task.

Events use the existing encrypted, sequence-checked BLE session and are scoped
to the subscribing device and subscription generation. Old peers that do not
advertise `taskUrls: 1` are not sent the new subscription command. The Mac's
background receiver owns one phone-shaped status item, present only while a
validated URL is available. Clicking opens the URL through `NSWorkspace`, using
the default browser. No URL goes through distributed process notifications.
Suggestions clear on unsupported tasks, lost authentication, receiver shutdown,
or eight seconds without a refreshed event. This works between mirror sessions.

This is assist-content and task-intent URL discovery, not full Continue On
payload extraction. It reads the app-published web URI, not screenshot pixels,
page bodies, arbitrary intent extras, or login credentials. Apps that do not
publish a URL or support the Docs conversion produce no suggestion.
App-specific URI mappings and hidden task APIs may need maintenance. The base
intent can be stale if an app changes content without updating it; document
switching was verified for Docs' separate-task path only.

Validation: `bash Native/test-task-continuation.sh` covers URL rules, malformed
metadata, authentication, expiration and clearing, plus the status item's button
and browser action. The production `TaskUrlReader` was also compiled to DEX and
run read-only through ADB against Docs and Tangent, returning their current URLs.
The permission-checked assist lookup also returned Chrome's current URL. URL
policy tests cover preferring a fresh assist URL, rejecting a stale browser launch
URL when no live URL exists, unsafe URIs, and retaining the Docs conversion.
Full live BLE + Shizuku behavior requires installing matching builds. End active
mirror sessions gracefully before either app is updated.

Investigated by Jeffrey Turkstra on 2026-10-18 using the connected Pixel 8,
Android 17 / API 37, build `CP3A.261005.005`.

## Observed on the device

ADB shell exposes `task_continuity`, implementing
`android.companion.datatransfer.continuity.ITaskContinuityManager`.
These read-only commands work (choose one authorized ADB serial):

```sh
adb -s SERIAL shell cmd task_continuity handoff help
adb -s SERIAL shell cmd task_continuity handoff list-controller-states
adb -s SERIAL shell cmd task_continuity handoff list-tasks 0
adb -s SERIAL shell cmd task_continuity handoff list-remote-tasks 0
```

Controllers for users 0 and 11 were enabled. Neither user had any
handoff-eligible tasks; user 0 also had no remote tasks. Therefore this test
did **not** capture an actual app's handoff payload. Ordinary recent tasks
were present; their existence does not imply Continue On support.

`dumpsys package com.android.shell` showed these permissions granted:

- `READ_REMOTE_TASKS`
- `REQUEST_TASK_HANDOFF`
- `READ_HANDOFF_SETTINGS` and `MODIFY_HANDOFF_SETTINGS`
- `USE_COMPANION_TRANSPORTS` and `DELIVER_COMPANION_MESSAGES`
- `ACCESS_COMPANION_MESSAGE_PCC`
- `MANAGE_ACTIVITY_TASKS`

A temporary `app_process` reflection probe confirmed these device APIs:

- `RemoteTask`: package name, label, icon, task ID, last-used timestamp,
  foreground state, handoff-enabled state, companion association ID and name.
- `HandoffActivityData`: component name, persistable extras, fallback URI.
- `TaskContinuityManager`: remote-task listeners, feature-state listeners,
  and `requestHandoff(associationId, taskId, executor, callback)`.
- The Binder interface additionally takes a user ID for those operations.
- `IHandoffTaskDataReceiver`: success callback with task ID and data list,
  or failure callback with task ID and reason. Its presence alone does not
  establish an accessible local payload-request API.
- `IActivityTaskManager` exposed `reportHandoffActivityData`, but no
  corresponding direct request method was found in that interface.

The diagnostic shell supports `push-task USER_ID ASSOCIATION_ID TASK_ID`.
It was not executed: it initiates a handoff, rather than merely reading metadata.
No app installation, restart, settings change, association creation, or mirror
session interruption was performed.

## Meaning for macOS

[Android's Continue On documentation](https://developer.android.com/develop/better-together/continue-on/enable-support)
requires each activity to enable handoff and supply its resume data. Enabling
the per-app setting alone does not make an arbitrary app export its current
state. An app can supply an Android component, optional extras, and an optional
web fallback, or explicitly supply a web handoff.

A DroidMirror implementation appears worth prototyping, but is not yet proven:

1. Use a known supporting activity (or a separate small test APK) that returns
   a fixed HTTPS fallback and recognizable extras. Check that it becomes eligible.
2. Investigate the local payload retrieval path or companion association and
   transport protocol. The observed remote-task listener describes tasks on
   another associated device; it is not a demonstrated local task-data feed.
3. Test the required calls from the Shizuku shell service. ADB permission grants
   suggest a route but do not prove that every operation, attribution check,
   association policy, or hidden API will work through the existing service.
4. Transfer validated metadata through DroidMirror's authenticated, encrypted
   channel, preserving authentication and sequence checks. Keep this opt-in.
5. Present the task on macOS and open its HTTPS fallback on explicit selection.
   Native Mac resume requires app-specific support for the supplied state.
   An Android component and extras cannot generally recreate an app on macOS.

Any companion transport implementation and real-payload extraction remain
unvalidated. The current evidence establishes diagnostic visibility and API
presence, not working cross-platform handoff.

## Follow-up: Google Docs URL extraction

Opening a document in Google Docs produced handoff-eligible task 13082 in user 0.
Its `KixEditorActivity` base intent contained `content://uniqueId/DOCUMENT_ID`.
`DocsTaskUrlProbe.java` successfully read this through the structured hidden API
`IActivityTaskManager.getRecentTasks(100, 0, 0)`, accessed the returned task's
`baseIntent.getData()`, and constructed
`https://docs.google.com/document/d/DOCUMENT_ID/edit`. The probe prints JSON for
one explicitly selected task and validates its package, editor activity, URI
scheme, authority, path count, and document ID before constructing a URL.

This is an app-specific task-intent extraction, **not extraction of Android 17's
handoff payload**. It does not capture document tab, cursor, or scroll position.
Base intents may be stale if the same task changes documents without updating
its base intent; compare against the current document before relying on this in
the product. The Docs URI convention and hidden API may change between versions.
The Mac browser still needs access to the document through its own Google login.

Live checks: the open Docs task returned a URL. A negative probe selecting Gmail
task 13079 exited with `Killed` (137), without a diagnostic, so rejection behavior
was not confirmed on-device. No private document URL is recorded in this file.

After the user switched to another document, Docs created foreground task 13084
instead of reusing 13082. The eligible-task list followed the new task, and the
same structured probe returned a different document ID and URL for task 13084.
This validates switching through this observed path; same-task document changes
remain untested. Resolve the current task dynamically rather than retaining a
previous task ID or URL.

To reproduce (adjust SDK/JDK paths and select the current task ID):

```sh
mkdir -p /tmp/droidmirror-docs-probe
javac -source 8 -target 8 -classpath "$ANDROID_HOME/platforms/android-37.0/android.jar" \
  -d /tmp/droidmirror-docs-probe Native/DocsTaskUrlProbe.java
"$ANDROID_HOME/build-tools/36.1.0/d8" \
  --lib "$ANDROID_HOME/platforms/android-37.0/android.jar" \
  --output /tmp/droidmirror-docs-probe \
  /tmp/droidmirror-docs-probe/DocsTaskUrlProbe.class
adb -s SERIAL push /tmp/droidmirror-docs-probe/classes.dex /data/local/tmp/droidmirror-docs-probe.dex
adb -s SERIAL shell 'CLASSPATH=/data/local/tmp/droidmirror-docs-probe.dex app_process /system/bin DocsTaskUrlProbe TASK_ID'
adb -s SERIAL shell rm /data/local/tmp/droidmirror-docs-probe.dex
```
