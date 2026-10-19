package com.genymobile.scrcpy.control;

public final class GesturePillTest {
    public static void main(String[] args) {
        for (int mode : new int[]{-1, 0, 1, 3}) {
            assert !GesturePill.contains(mode, 540, 2380, 1080, 2400, 3, 72);
        }
        assert GesturePill.contains(2, 540, 2380, 1080, 2400, 3, 72);
        assert GesturePill.contains(2, 370, 2341, 1080, 2400, 3, 72);
        assert !GesturePill.contains(2, 540, 2339, 1080, 2400, 3, 72); // app content
        assert !GesturePill.contains(2, 100, 2390, 1080, 2400, 3, 72); // outside pill
        assert !GesturePill.contains(2, 540, 2400, 1080, 2400, 3, 72);
        assert !GesturePill.contains(2, 540, 2380, 1080, 2400, 3, 0); // hidden/unknown strip
        assert !GesturePill.contains(2, 540, 2370, 1080, 2400, 3, 24); // never exceed inset
        assert GesturePill.contains(2, 1200, 1070, 2400, 1080, 3, 72); // landscape
        assert GesturePill.contains(2, 180, 795, 360, 800, 1, 24); // low density
        assert GesturePill.isTap(540, 2380, 544, 2378, 24, 100);
        assert !GesturePill.isTap(540, 2380, 540, 2330, 24, 100); // swipe replay
        assert !GesturePill.isTap(540, 2380, 540, 2380, 24, 251); // hold replay
        GesturePill.Clicks clicks = new GesturePill.Clicks();
        assert clicks.click() == 1;
        assert clicks.take(clicks.token()) == 1; // Home
        assert clicks.click() == 1;
        long single = clicks.token();
        clicks.pause();
        assert clicks.take(single) == 0; // cancelled timer cannot fire while next click is held
        assert clicks.click() == 2;
        long doubleClick = clicks.token();
        assert clicks.take(doubleClick) == 2; // Recents
        assert clicks.take(doubleClick) == 0; // never duplicate
        assert clicks.click() == 1;
        assert clicks.click() == 2;
        assert clicks.click() == 3;
        assert clicks.take(clicks.token()) == 3; // long Home, no preceding Home/Recents
        clicks.click();
        long stale = clicks.token();
        clicks.cancel(); // drag, mode change, disconnect or unrelated click
        clicks.click();
        assert clicks.take(stale) == 0;
        assert clicks.take(clicks.token()) == 1;
        System.out.println("PASS: gesture-only gating, bounded hit target, density/rotation, tap/drag/hold, click sequences and stale timers");
    }
}
