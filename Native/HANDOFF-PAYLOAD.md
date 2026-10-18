# Actual Android handoff payload investigation

Investigated by Jeffrey Turkstra on 2026-10-18 against the Pixel 8 running Android
17 API 37, build CP3A.261005.005.

## Outcome

Gmail's compose activity was handoff-eligible, but no actual Gmail handoff payload
or draft fallback URL was retrieved. This path has not been added to production.
Assist-content URL discovery and the Docs adapter remain the implemented sources.
Eligibility alone does not prove that this installed Gmail build will return a
usable website fallback.

## Request path

The public Android 17 AOSP source places the local request in
`ActivityTaskManagerService.requestHandoffTaskData(taskId, receiver)`. It is
exposed to other system-server components through `ActivityTaskManagerInternal`,
not through `IActivityTaskManager`. That Binder interface exposes the app's
`reportHandoffActivityData` response, but not a matching request entry point.

The continuity service's inbound handler calls the internal request, collects
the returned `HandoffActivityData` objects, and serializes a
`HandoffRequestResultMessage`. Each activity message can contain a `fallbackUri`.
Thus requesting and decoding the actual companion protocol is the relevant
route; task intents and assist-content lookups are separate mechanisms.

The device's `cmd task_continuity handoff` exposes eligible task listing and
`push-task USER_ID ASSOCIATION_ID TASK_ID`, but no local payload-dump command.
No handoff was pushed to the user's watch, earbuds, car, or another device.
No companion associations were created or altered during this investigation.

## Secure transport test

A temporary shell probe loaded the device's actual `SecureTransport` and
`Transport` implementations from `/system/framework/services.jar`. It constructed
two endpoints over a local socket pair using normal encrypted transport,
attestation, and zero override flags. It did not open a network connection or
disable transport authentication.

The shell process first needed Android's standard keystore provider installed
in-process. The next attempt encountered a keystore provisioning failure. A
further attempt generated attestation but failed verification on both endpoints:

```text
CDM_AttestationVerifier: AVF verification failed with error code: 8
AttestationVerificationException: Remote device failed to verify local attestation.
```

In the AOSP verification flags, 8 is
`FLAG_FAILURE_LOCAL_BINDING_REQUIREMENTS`. The normal CDM attestation verifier
adds `android.key_owned_by_system=true`. A key generated under Shizuku/ADB shell
UID is not a system-owned key. This establishes a blocker for the tested secure
shell-peer approach, not a proof that every possible companion integration is
impossible. A privileged system integration or a supported authenticated
non-Android companion transport would require separate investigation.

The only transport override found in the inspected manager was global. It was
not used. An emulated transport discards outgoing messages, so it cannot return
the payload to our reader. A production feature should not depend on changing
global transport security or scraping payloads from debug logs.

## Product implications

Do not advertise Gmail draft continuation as implemented until a real fallback
URL has been extracted and validated. Do not manufacture a draft URL from local
IDs or infer successful extraction from the eligible-task list.

When a supported retrieval route exists, validate the task and package, accept
only HTTP/HTTPS fallback URLs, keep payload extras local, and retain the existing
encrypted BLE authentication and sequence checks. Treat a live handoff request
as an explicit continuation action: apps receive `isActiveRequest=true` and can
react to it, so it should not be blindly polled every two seconds like metadata.

## Source references

- https://android.googlesource.com/platform/frameworks/base/+/refs/heads/android17-release/core/java/android/app/IActivityTaskManager.aidl
- https://android.googlesource.com/platform/frameworks/base/+/refs/heads/android17-release/services/core/java/com/android/server/wm/ActivityTaskManagerService.java
- https://android.googlesource.com/platform/frameworks/base/+/refs/heads/android17-release/services/companion/java/com/android/server/companion/datatransfer/continuity/handoff/InboundHandoffRequestHandler.java
- https://android.googlesource.com/platform/frameworks/base/+/refs/heads/android17-release/services/companion/java/com/android/server/companion/securechannel/AttestationVerifier.java
- https://android.googlesource.com/platform/frameworks/base/+/refs/heads/android17-release/core/java/android/security/attestationverification/AttestationVerificationManager.java
