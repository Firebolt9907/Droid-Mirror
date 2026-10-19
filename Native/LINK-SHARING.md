# Link sharing

- Mac: Share → DroidMirror → Open on Phone.
- Android: Share → DroidMirror. The activity reports whether the Mac opened its browser.
- Both apps must be updated and paired over Bluetooth. The phone must be Ready for Mac;
  the Mac receiver runs independently of a mirror window. Mac-to-phone browser launches
  require Shizuku authorization and a configured Android default browser.
- The Mac extension can be enabled in macOS’s Share menu if it is initially hidden.
- Only one HTTP/HTTPS link per share is supported. Android accepts a title followed by
  one link. Files, credentials in URLs, and non-web schemes are rejected.

The macOS Share extension hands the URL to the notification receiver inside its own
containing app. The receiver validates it again and sends an `openLink` request with
an ID over the existing encrypted, authenticated, sequenced BLE connection. Android
rechecks the originating session before dispatching to the Shizuku user service;
that service validates the URL and resolves the browser role before launching an
explicit browser intent. Arguments are passed directly to processes, without a shell.

`linkSharing: 1` capability negotiation and `linkSubscribe` prevent older installations
from receiving new messages. Android shares use `shareLink` and receive a
`shareLinkResult` acknowledgment after macOS dispatches to its default browser.
Mac-to-phone requests receive `openLinkResult`. Requests expire after 15 seconds and
are never automatically resent after a successful BLE enqueue; the Mac remembers
64 recently received request IDs to avoid opening duplicate incoming shares.
A missing acknowledgment means delivery is uncertain, since a browser may have opened
just before the Bluetooth connection dropped. No URL is persisted or logged.

Builds include `Contents/PlugIns/DroidMirrorShare.appex`, signed with the app’s identity
and its App Sandbox entitlement. Build or stage updates first; end active mirrors
gracefully before installing/restarting either app.

Validation: `bash Native/test-link-sharing.sh`, `bash Native/test-task-continuation.sh`,
compile the BLE library and receiver using `build-app.sh`’s source list, and build the
Android app with Gradle. Device QA should exercise Safari/Chrome share menus, both
directions, browser defaults, unavailable peers, disabled Shizuku, and disconnects
while sharing. Actual browser display and system share-menu registration require
on-device verification.
