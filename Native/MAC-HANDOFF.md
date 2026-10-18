# Mac to Android continuation feasibility

Investigated by Jeffrey Turkstra on 2026-10-18 on macOS 27.0.1 (26A434).

## Findings

Apple's public `NSUserActivity` API lets an app publish its own activities and
receive activities addressed to it. It does not expose a public feed of every
other application's current Handoff payload. Apple's Handoff programming guide
restricts native app-to-app continuation by developer team and activity type.
Apple's platform security guide describes encrypted, authenticated BLE activity
advertisements with replay protection and iCloud device pairing. Listening to
advertisements alone therefore does not provide plaintext URLs.

The local `UserActivity.framework` runtime exposes private methods including:

- `+[NSUserActivity _currentUserActivityUUIDWithOptions:completionHandler:]`
- `+[NSUserActivity _currentUserActivityProxiesWithOptions:matching:completionHandler:]`
- `+[NSUserActivity _fetchUserActivityWithUUID:completionHandler:]`
- `UAUserActivityManager` current activity and proxy methods.

A temporary, read-only Objective-C probe loaded the system framework and queried
the first two methods. It was also run outside the tool sandbox so a filesystem
sandbox restriction would not be mistaken for macOS's own access control.

The current UUID call returned nil. The proxy query returned an empty array and:

```text
Error Domain=UAContinuityErrorDomain Code=-135
UserInfo={entitlement=com.apple.private.coreservices.allowedToMatchUserActivities}
```

This is direct evidence that the tested cross-activity query is protected by an
Apple-private entitlement. Merely finding a selector or adding a claimed
entitlement to an ordinarily signed app does not establish usable access.
No keys were extracted, protections disabled, or system daemons modified.
No actual cross-app Handoff payload was retrieved.

## Practical product path

Reverse URL continuation remains feasible without intercepting Apple's Handoff:

1. A browser extension supplies a validated HTTP/HTTPS URL, using explicit
   activation or narrowly scoped permissions for automatic current-tab access.
2. A native messaging connection passes it to DroidMirror.
3. DroidMirror sends a bounded, expiring suggestion over its authenticated BLE
   channel, with origin/direction handling to prevent continuation loops.
4. Android shows a user-selectable continuation suggestion. On selection, open
   it with `ACTION_VIEW`; Android may resolve a supported app link to a native
   app, otherwise to a browser. Do not launch an app automatically on arrival.
5. Other Mac apps can supply URLs through a Share extension or individual
   supported integrations. Unsupported activities stay silent.

This path has not been implemented or tested here. Native state without a
cross-platform URL still needs a per-app adapter or cooperating app. A browser
extension does not cover arbitrary native Mac apps.

## Sources

- https://developer.apple.com/documentation/foundation/nsuseractivity
- https://developer.apple.com/library/archive/documentation/UserExperience/Conceptual/Handoff/AdoptingHandoff/AdoptingHandoff.html
- https://support.apple.com/guide/security/handoff-security-secf78dbe639/web
- https://developer.chrome.com/docs/extensions/develop/concepts/native-messaging
- https://developer.chrome.com/docs/extensions/develop/concepts/activeTab
- https://developer.apple.com/documentation/safariservices/messaging-a-web-extension-s-native-app
- https://developer.android.com/guide/components/intents-common#Browser
