# Gesture-pill clicks

The shared Android `Controller` intercepts primary mouse clicks on the centered
bottom navigation pill. This covers ADB and the Bluetooth companion without a
Mac overlay that can obstruct app controls. The companion must be rebuilt and
installed for Bluetooth sessions to use a changed Android controller.

- One click: Home.
- Two clicks: Recents / app switcher.
- Three clicks: long Home (Circle to Search if enabled and supported by the phone).

Android's secure `navigation_mode` setting is read for each click and before
dispatch; `config_navBarInteractionMode` is the fallback. Only mode 2 is eligible.
Modes 0 (three buttons), 1 (two buttons), unavailable mode/geometry, and secondary
displays retain ordinary input. The values are defined in the
[Android gesture navigation overlay](https://android.googlesource.com/platform/frameworks/base/+/refs/heads/main/packages/overlays/NavigationBarModeGesturalOverlay/res/values/config.xml).

The hit target is centered, 120dp wide (at most 44% of display width), and 20dp
high, capped by `navigation_bar_height`. These are physical Android dp converted
using the current display density after mapping from video coordinates, so resizing
the Mac window and stream downscaling do not inflate the target into app content.
The connected 1080×2400 / 420dpi phone reports a 24dp navigation bar: the target is
315×52.5 physical pixels inside that strip. This uses the configured navigation-bar
height; immersive visibility and vendor-specific hidden-pill settings are not queried.

Single and double clicks wait 350ms after release to distinguish a third click,
without firing the earlier actions. Motion beyond 8dp or a hold over 250ms replays
the withheld down and resumes ordinary touch delivery. A held next click pauses
the previous deadline. Generation tokens discard stale callbacks. Mode changes,
unrelated clicks, drags and controller shutdown cancel pending shortcuts. Long
Home uses Android's long-press timeout and repeat/long-press flags, then releases.
The phone chooses the action assigned to long Home; DroidMirror does not launch
a Google activity directly.

Run the platform-independent regression test:

```sh
javac -d /tmp/droidmirror-pill-tests \
  scrcpy-5.0/server/src/main/java/com/genymobile/scrcpy/control/GesturePill.java \
  Native/tests/gesture-pill/GesturePillTest.java
java -ea -cp /tmp/droidmirror-pill-tests com.genymobile.scrcpy.control.GesturePillTest
```

`GesturePillPhoneProbe.java` is a read-only device probe, compiled against the
Android SDK and companion classes and run with the customized server on the
`app_process` classpath. It constructs the real controller and checks its mode and
hit-testing methods without injecting input. On the connected phone it confirmed
mode 2, the pill center hit, and exclusion of app content and screen edges.
Home/Recents/Circle to Search actions and visual behavior still need an interactive
phone check; tests do not claim to exercise those system UI transitions.

Build artifacts: `./build-app.sh` builds/packages the ADB server; the companion's
`JAVA_HOME=$(/usr/libexec/java_home -v 21) ANDROID_HOME=~/Library/Android/sdk ./gradlew assembleDebug` compiles the same
controller. The manual server build includes nested classes in DEX output so the
scheduled callbacks and policy state are present in the packaged server.
