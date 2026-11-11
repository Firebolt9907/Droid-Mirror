# ESPN activity forwarding

The Android decoder and native Mac presentation port the sports behavior in
`~/Github/dynamic-island`: football field position and first-down targets,
continuous-possession movement history, baseball source-authored bases and outs,
set scores, possession/serving/batting, pregame broadcasts, and rotating-panel
context memory. This is notification data, not an independent sports feed.

Football targets require both down-and-distance and a named yard line. Direction
requires an explicit possession marker. The movement trail is observed movement
between notifications (it can include penalties), not a claim about a completed
play. The bright segment is the last observed movement and resets on a change of
teams, phase, score or possession. The faint drive segment runs from the first spot
observed after possession changed; it survives quarter changes and panels without a
possession marker, and resets on a team, score or possession change and at
halftime/final. The ball and first-down marker animate between spots.

ESPN score panels replace down & distance with the play text, or briefly keep the
stale pre-score down & spot (which is then hidden, along with the first-down
marker). When a spotless or stale-spot panel shows exactly one team's score rising in a game that already had a field,
the Mac keeps the field, slides the ball into the scorer's attacking end zone
(a safety therefore lands in the offense's own end zone), tints that end zone and
labels it "TEAM · Touchdown/Field goal/Safety/Extra point" from the points gained.
A follow-up extra point or two-point try continues the same scoring play. The
next real spot, halftime or final clears it. Context omitted
by rotating panels can be retained for at most 120 seconds from its original
observation; clock/image updates do not renew that deadline.

Generic ESPN indicator images are matched against the source package's known
possession/tennis drawable alpha masks. Winner/favorite arrows, possession
percentages and unsupported ambiguous markers are not possession. Baseball
occupancy remains the original source image; outs and set scores require explicit
source values.

Chronometer fields run the original Android widget with public view visibility
and handler APIs. RemoteViews owns its start/stop/base/countdown/format commands.
There is no overlay, private started-flag inspection, inferred clock advancement,
or clock extrapolation on the Mac. Static TextViews remain static. At most eight
notification clock bindings run; they stop on removal, loss of an authenticated
subscriber, listener teardown, or cache eviction. If source inflation is not
supported, the latest reported text is retained instead.

Mac-specific behavior remains native popover glass, team-color compact fades,
logos before first reveal, stable items/controllers during updates, click-to-open
in mirroring, and score-increase-only ticker animation. Android camera/notch
placement and automatic expansion/celebration effects are intentionally not
introduced into the native menu bar.

ESPN uses at most 32 native nodes. Semantic sports nodes omit irrelevant source
pixel boxes so graphics, player rows and set scores fit the bounded wire payload.
Images use the existing authenticated, content-addressed chunk channel.

## Checks

- `bash Native/test-android-activities.sh` — native sport parsing, field/history,
  context lifetime, pregame, sets, marker semantics and existing item/action tests.
- `bash Native/test-activity-images.sh` — artwork hydration, moving node indices,
  deduplication and bounded asset handling, including node 31.
- `ActivitySportsFieldsTest` and `ActivityLayoutBudgetTest` in
  `BluetoothCompanion/tests` run against compiled Kotlin classes.
- `python3 tools/test-source-game-clock.py` — isolated Android `app_process` test
  for paused/running/stopped clocks and callback cleanup. Requires one authorized
  device and compiled Kotlin output. It does not install an APK or replace any
  running Shizuku process.

The native preview executable renders `sport-football.png`, `sport-baseball.png`,
`sport-tennis.png`, `sport-pregame.png`, and `sports-context-gallery.png` using
explicitly labeled sample data.
