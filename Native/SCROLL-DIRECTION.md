# Input-specific vertical scrolling

The retained style controller reverses vertical emulated scrolling for all input
sources. `ScrollDirection.m` removes that extra reversal from ordinary mouse-wheel
increments only. Touch events preserve their previous behavior and sensitivity;
horizontal scrolling and direct SDL input are unchanged.

AppKit precise-delta/gesture/momentum metadata distinguishes touch scrolling from
ordinary wheel ticks. This covers trackpads and phase-less precise Magic Mouse
events. A utility that converts wheel input into indistinguishable precise touch
events may require additional device-specific handling; no global event tap or
Accessibility permission is used.

The scope is one `NSApplication.sendEvent:` dispatch, during which the existing
local scroll monitor accumulates wheel deltas. The setter compensates each new
increment rather than negating the total, so multiple ticks accumulate correctly.
An asynchronous swipe flush outside event dispatch clears normally. Nested event
dispatch restores the prior scope using `@finally`.

Build the style shim with `Native/ScrollDirection.m` alongside
`KeyboardPassthroughShim.m`, `DeviceCorners.m`, and `CornerResize.m`, then sign with
`sh Native/sign-droidmirror.sh`.

Tests:

```sh
xcrun clang -fobjc-arc -framework AppKit Native/ScrollDirection.m Native/ScrollDirectionTests.m -o /private/tmp/droidmirror-scroll-direction-tests
/private/tmp/droidmirror-scroll-direction-tests
```
