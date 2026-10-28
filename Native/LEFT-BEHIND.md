# Mac left-behind radio experiments

Enable **Mac left-behind alerts (experimental)** in Android's **Notifications
and left-behind alerts** screen. Keep the background bridge enabled and the
paired Mac's DroidMirror background receiver running. Install matching Mac and
Android builds. Allow Nearby Devices and notifications. Significant-motion
hardware is required; it approximates travel without classifying walking/biking.
On Android 11 and earlier, BLE scanning also requires the existing location
permission and Android's Location setting.

Four detectors run in parallel, each with its own **MacBook left behind? #N**
notification and persistent firing count:

1. **Authenticated BLE link:** the existing Mac-central → phone-peripheral
   notification connection. Loss of the last authenticated physical link is the
   observation; session/security rediscovery alone is not separation.
2. **Passive Mac BLE beacon:** the Mac advertises a pairing-specific service UUID;
   the phone scans for it. This needs no connection. It is deliberately a lower
   confidence measurement: an advertisement can be recorded/spoofed. It grants
   no trust or command access.
3. **Phone-initiated BLE GATT challenge:** the phone is the central, the Mac is a
   peripheral. The phone connects, discovers the dedicated presence service,
   writes a fresh 16-byte nonce, and reads a 32-byte HMAC proof. A remembered
   address lets this probe try connecting even when an advertisement is missing.
   It succeeds only with a valid proof from the paired Mac, not merely a
   successful connection. Initial discovery shares #2's scan, so these channels
   are not statistically independent.
4. **Phone-initiated Bluetooth Classic RFCOMM challenge:** a separate Mac SDP/
   RFCOMM presence service, independent of BLE. The phone sends a fresh nonce
   over a real socket and validates a transport-specific HMAC response. Cached
   SDP UUIDs, device names, bonding and ACL connection alone never count as
   success. **Pair the Mac in Android system Bluetooth settings first.** The
   experiment targets the Mac explicitly selected in DroidMirror pairing.
   If no Mac is selected, it may reuse a previously cryptographically verified
   address for this pairing. It never cycles through other bonded computers.
   An unbonded selected target is unavailable, not a miss. Probes have a 20-second
   deadline and show whether failure occurred opening the socket, writing the
   nonce, or reading the response. Cached names label the target, not presence. It does not start pairing automatically.

The Mac's presence-only endpoints do not execute commands or grant access to
mirror/notification sessions. Both active transports use the notification pairing
key with separate HMAC labels and fresh random nonces for every attempt. A
response from a previous attempt, another key, or another transport fails
verification. Existing mirror authentication and sequence checks are unchanged.
The Mac bounds pending GATT challenges, Classic connections and their lifetimes.

## Sampling and alerts

On enable/reset, the phone takes one initial sample even while stationary, so
working channels can arm nearby. Another authenticated BLE connection requests a
warmup sample. While significant motion is recent (last two minutes), radio
rounds start at most once per minute. A round scans for 20 seconds, tries a
bounded GATT connection/read, and tries one Classic socket concurrently. Probes
close afterward. While stationary there is no continuous scan or connection
loop; there is a lightweight bridge-owned timer. Android idle modes can delay
all these callbacks; this is not an exact once-per-minute wake guarantee.

Each channel must first succeed nearby before it can alert. The three sampled
channels require two completed misses at least 45 seconds apart, plus recent
movement. #1 uses a 45-second physical-disconnect grace period plus recent
movement. A channel fires once until **that same channel** reports presence
again; another detector's success does not mask its failures. Separations expire
after ten minutes. Reappearance rearms that channel and records recovery in the timestamped
history. Notifications survive normal reconnection so short absences do not
vanish before the user notices them; bridge shutdown/disarm still clears them. Permission/scanner/radio unavailability is recorded separately and breaks the
miss streak. An absent/invalid remote response counts as a miss, including sleep
or interference: comparing those false positives is the experiment's purpose.

#1 notifications are muted by default based on the first field trials; its
connection is still monitored. Per-channel switches control notifications, not
radio sampling. Existing notification-post counters are preserved.

Settings shows persistent notification counts and probe success/miss/unavailable
counts, plus the most recent status per channel, and refreshes while open.
It displays separate SCAN/CONNECT permission status and requests missing detection
permissions when reopening an enabled experiment. The Allow detection permissions
button retries that request. Missing BLE SCAN permission blocks #2 and initial
#3 discovery, but does not block Classic #4. Tap Reset to begin a new tally. #1 is a persistent connection, not a sampled
probe, so its probe totals are not directly comparable. Counts record successful
notification submissions, not proof that Android displayed/sounded an alert or
that it was a true positive. Disabled notifications do not consume an alert.
The old five timing-policy counters are retained but are not mixed with these
new radio-channel counts. Resetting counts does not rearm a fired channel.

Phone bridge stop, trust reset, local Bluetooth shutdown, and process restart
clear live detection state and close probes; counters survive. Changes to trust
are checked before new probes. The Mac server follows the receiver's lifecycle,
refreshes on pairing changes and Bluetooth state changes, and removes its
services when stopped. This does not keep the Mac awake: lid-closed behavior,
Bluetooth off, app shutdown/update, and radio interference can all cause misses.

## Verification and field testing

Run `bash Native/test-left-behind.sh` for independent-channel policy tests,
cross-language UUID/proof vectors, nonce and transport separation, unavailable
states, alert deduplication, rearming and expiry. Run
`bash Native/test-ble-session.sh` to compile/link the actual Mac receiver and
check existing session policy. Build Android with `:assembleDebug`.

Compilation and deterministic tests do not establish radio reliability. Validate
all four channels nearby before walking away: each should show success, not just
zero alerts. Then compare phone-only departure, carrying both devices, lid-open
and lid-closed sleep, screen lock/idle, transient interference, reconnection,
permissions revoked, Bluetooth off and bridge stop. Tally true positives by the
notification number. #2 can be spoofed; #3/#4 require fresh cryptographic proof.

Before installing either update, end active mirroring and stop/quit the old
components gracefully. Replacing an active BLE service is not seamless; an atomic
bundle replacement alone does not preserve a running session.

## Second field trial (2026-10-26)

Screenshot totals: #1 112 notification posts; #2 10 posts, 1076 successful probes,
215 misses, 139 unavailable; #3 21 posts, 1007 successes, 287 misses,
139 unavailable; #4 zero posts, zero successes, 1294 misses, 139 unavailable.
The user finds #1 too noisy to use. #2/#3 were both noticed on departures,
including a recent test in which #2 appeared after about one minute and #3 after
two. There is no deliberately different delay: both require two misses and a
45-second absence, but #3 can have a different last success/failed round. Their
shared discovery also means these are not fully independent measurements.

The old #4 code rotated through all bonded computers until a proof succeeded.
The Windows/CachyOS laptop name reported by the user is consistent with a cached
bond record used as a probe target, not evidence of a live computer nearby. Those
1294 historical misses can include attempts against other computers; zero
successes means #4 never armed. The new target restriction and stage-specific
errors improve diagnosis; they do not establish that Classic now works.

Historical counts measured notify() submissions. They cannot reconstruct how
many banners/sounds the user noticed. Reused notification IDs replace cards,
normal reconnection previously removed them, and a single successful observation
rearms a channel. Thus another short dropout can post again. New builds retain a
bounded history of the last 60 posts/recoveries with timestamps, label counts as
notification posts, and preserve cards across normal reconnects. Existing counts
and historical unavailable results remain unchanged. No historical event log can
be recovered retroactively.

## Correct / Incorrect / Unanswered feedback

New notifications include **Correct** and **Incorrect** actions. Each uses a
unique immutable PendingIntent pointing to an app-private receiver and a unique
notification event ID. The first completed decision/removal wins; stale or
repeated actions cannot modify a completed event or cancel a newer notification.
Choosing an answer records it and removes only that exact active notification.
Opening the settings page from the notification does not dismiss it.

A separate SQLite log retains every new event, algorithm, posting timestamp,
probe detail, answer, observed posted lifetime, and end reason. Settings shows
per-algorithm decision totals and the most recent 40 entries. Radio counter resets
do not erase this decision log. Older notification totals cannot be assigned
feedback or durations retroactively.

While an alert is still posted, it appears as `unanswered (2m 3s; still posted)`
with an increasing lifetime. A swipe/clear, replacement by a later alert from the
same algorithm, muting, or bridge shutdown closes it as unanswered with the
observed duration and reason. Correct/Incorrect entries also retain the elapsed
time until the choice. Timings use elapsed realtime and boot identity, so wall
clock changes do not distort them. This measures how long the notification was
posted, not how long a heads-up banner was on screen or whether the user saw it.

The bridge reconciles the OS active-notification list every 15 seconds. If a
system removal was missed while the process was stopped, only the last observed
lifetime is retained and marked as such. Across reboot, duration is unknown.
These uncertain removals are not reported as exact lifetimes. A process killed
in the tiny create/post interval may leave an incomplete posting record; stale
incomplete records are discarded, not counted as answered/unanswered alerts.
