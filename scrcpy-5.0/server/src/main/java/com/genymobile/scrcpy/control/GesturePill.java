package com.genymobile.scrcpy.control;

/** Click policy in physical display pixels, independent of Android for regression tests. */
final class GesturePill {
    static final long CLICK_MS = 350;
    static final long MAX_HOLD_MS = 250;

    private GesturePill() { }

    static final class Clicks {
        private int count;
        private long generation;

        long pause() {
            return ++generation;
        }

        int click() {
            ++generation;
            return ++count;
        }

        long token() {
            return generation;
        }

        int take(long token) {
            if (token != generation) {
                return 0;
            }
            int result = count;
            cancel();
            return result;
        }

        void cancel() {
            ++generation;
            count = 0;
        }
    }

    static boolean contains(int mode, int x, int y, int width, int height, float density, int navHeight) {
        if (mode != 2 || width <= 0 || height <= 0 || density <= 0 || navHeight <= 0) {
            return false;
        }
        // A centered 120dp target with a 20dp height, always inside the system navigation strip.
        // Never reserve the full screen width or a percentage of the app's content height.
        float halfWidth = Math.min(60 * density, width * 0.22f);
        float hitHeight = Math.min(20 * density, navHeight);
        return x >= width / 2f - halfWidth && x <= width / 2f + halfWidth
                && y >= height - hitHeight && y < height;
    }

    static boolean isTap(int startX, int startY, int x, int y, float slop, long duration) {
        long dx = (long) x - startX;
        long dy = (long) y - startY;
        return duration <= MAX_HOLD_MS && dx * dx + dy * dy <= slop * slop;
    }
}
