# Focus / Do Not Disturb sync

Both directions are off by default, independently, on both devices. No Shizuku code is changed and no service version bump is needed.

## Setup and behavior

In Mac Settings → Focus sync, enable the desired direction. Enable the matching switches in Android Background features and setup → Focus sync and grant **Do Not Disturb policy access**. Notification listener access is a different permission. The existing background BLE receiver owns sync; mirroring need not be active, but the paired authenticated BLE connection must be available.

Mac → phone uses `INFocusStatusCenter` (macOS 12+) with authorization and `NSFocusStatusUsageDescription` in both app bundles. The host requests permission when enabled; the separately identified background notification receiver also requests its own permission when connected. Share Focus Status must be enabled for the relevant Focus. A nil status, denial, restriction, or disconnected transport leaves the phone unchanged. This API reports **shared availability**, not the identity of a Focus or a guaranteed raw global switch. A Focus that does not share status can be invisible. Polling runs every three seconds while connected; rapid transitions can be coalesced.

Apple's Focus-status guidance also mentions the User Notifications Communication capability. As documented in [BLE integration](BLE-INTEGRATION.md), this repository's local development signing lacks the matching provisioning profile, and adding that restricted entitlement alone can prevent launch. This change does not inject it into development signing. Verify authorization and useful status on both actual signed bundle identities; if macOS enforces a capability restriction, Mac → phone remains unavailable until appropriately provisioned. No undocumented file fallback bypasses that restriction.

Focus on calls Android `setInterruptionFilter(PRIORITY)`; off calls `ALL`. On Android 15+ with this app's target SDK 35, these calls control an implicit app-owned AutomaticZenRule, **not global DND**: other rules can keep DND enabled. On older Android versions they affect the global filter. Priority uses Android's notification policy and allows configured exceptions. Previous filter settings are not restored automatically, including on disconnect or disabling sync; change DND manually if needed.

Phone → Mac observes `ACTION_INTERRUPTION_FILTER_CHANGED` and returns the current filter through authenticated queries every three seconds (queries run when either Mac direction is enabled). A transition in `canSet` from false to true republishes the Mac baseline after Android permission or its local setting is enabled. Priority, alarms-only, and total silence map to focused; ALL maps to unfocused; UNKNOWN is ignored. Enter two existing Shortcut names in Mac settings, one with a **Set Focus → On** action for your chosen Focus and one with **Set Focus → Off**. Test each manually in Shortcuts and allow its prompts first. The receiver invokes `/usr/bin/shortcuts run <name>` with separate process arguments, never a shell. macOS has no public general API to toggle Focus. Missing names do nothing. The CLI is sent termination after 15 seconds; errors appear in Mac settings and are not retried continuously. Terminating the CLI cannot guarantee cancellation of actions already dispatched to Shortcuts, so avoid prompts or long-running steps in these two Shortcuts. The first phone sample after connection or enabling phone → Mac applies its state; when both directions start and Mac status is known, the Mac baseline is sent first.

## Protocol and echo handling

No new characteristic or numeric message ID. The existing encrypted, authenticated, sequence-checked control envelope carries:

- `focusSet`: `focused` Boolean and `origin` UUID string (1–64 characters); changes Android only with its local Mac → phone switch and policy access.
- `focusQuery`: requests current Android state.
- `focusState`: `available`, `focused`, numeric `filter`, `canSet`, `origin`, and `error` (empty, `disabled`, `invalid`, or `policyAccessRequired`). `available` requires the Android phone → Mac switch, policy access, and a known stable filter.

Callbacks recheck the same authenticated session before applying work and before replying, so disconnect/re-authentication cannot reuse queued commands. The Android ready message advertises `focusSync: 1`; the Mac sends nothing to older companions without that capability. Android tags the resulting filter with the command origin; a subsequent local filter change clears it. A pending Android transition is suppressed for up to five seconds. The Mac consumes its own token without running Shortcuts. Shortcut-generated Mac changes become a baseline rather than a new outbound command, with a 15-second suppression window. Independent local changes after suppression resume sync. This is state sync, not transactional arbitration: concurrent edits or another Android rule can win; Focus identities and Android exception lists are not transferred.

## Alternatives and notification delivery

`SetFocusFilterIntent` is a public, per-Focus configuration mechanism. It requires users to install a filter for each desired Focus and adds an App Intents extension/metadata lifecycle. It does not discover every existing Focus automatically. It is a good future option for explicit per-Focus mappings, but was not chosen for this shared-availability toggle.

Reading `~/Library/DoNotDisturb/` assertion files would expose undocumented formats, race file replacement, and depend on privacy/sandbox access. It is deliberately not a fallback: unknown authorized status must not silently become an inferred off state.

Forwarded notifications continue through macOS UserNotifications with the existing passive/active policy, without time-sensitive or critical escalation. System Focus therefore controls delivery using the user's allowed-app and communication settings for **DroidMirror Notifications**. We do not discard notifications based on shared availability, which could lose allowed contacts and notifications intended for Notification Center. Configure that receiver app in each Mac Focus as desired.

## Verification and device checks

Run `bash Native/test-focus-sync.sh` for initial state, no-op transitions, echo consumption, bounded suppression, failed Shortcut behavior, duplicate phone snapshots, origin-tag echoes, and reconnect baselines. Compile BLE sources, the Swift host, and Android compile tasks without installing.

Still test on signed builds: authorization for both bundle identities; shared-status on/off and nil/denied cases; Android policy revocation and Android 15 app-rule semantics; each direction independently and together; local toggles, two-way simultaneous edits, reconnects, Shortcut failure/timeouts, and forwarded notification delivery under a Focus. No active mirror session should be replaced to perform this validation. End it gracefully before a later authorized update.

## References

- [Apple INFocusStatusCenter](https://developer.apple.com/documentation/intents/infocusstatuscenter)
- [Apple Focus filters](https://developer.apple.com/documentation/appintents/focus/)
- [Apple Focus usage description](https://developer.apple.com/documentation/bundleresources/information-property-list/nsfocusstatususagedescription)
- [Android NotificationManager](https://developer.android.com/reference/android/app/NotificationManager)
- [Android 15 DND behavior changes](https://developer.android.com/about/versions/15/behavior-changes-15#dnd-changes)
