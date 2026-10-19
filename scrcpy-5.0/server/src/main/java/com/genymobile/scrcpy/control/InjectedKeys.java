package com.genymobile.scrcpy.control;

import java.util.LinkedHashMap;
import java.util.Map;

/** Owns SDK-injected key presses for one controller, including releases lost on disconnect. */
public final class InjectedKeys {
    private static final int DOWN = 0;
    private static final int UP = 1;
    private static final int CANCELED = 0x20; // KeyEvent.FLAG_CANCELED: releasing must not activate a shortcut.

    public interface Injector {
        boolean inject(int action, int keycode, int repeat, int metaState, int displayId,
                long downTime, long eventTime, int flags);
    }

    private static final class Press {
        final int keycode;
        final int displayId;
        final long downTime;

        Press(int keycode, int displayId, long downTime) {
            this.keycode = keycode;
            this.displayId = displayId;
            this.downTime = downTime;
        }
    }

    private final Map<Long, Press> pressed = new LinkedHashMap<>();
    private boolean closed;

    public synchronized boolean inject(int action, int keycode, int repeat, int metaState, int displayId,
            long now, Injector injector) {
        if (closed || (action != DOWN && action != UP)) {
            return false;
        }
        long id = ((long) displayId << 32) | (keycode & 0xffffffffL);
        Press press = pressed.get(id);
        if (press == null) {
            press = new Press(keycode, displayId, now);
        }
        if (action == DOWN) {
            // Record before injection: a failure may occur after Android has already seen the event.
            pressed.put(id, press);
        }
        boolean ok = injector.inject(action, keycode, repeat, metaState, displayId, press.downTime, now, 0);
        if (ok && action == UP) {
            pressed.remove(id);
        }
        return ok;
    }

    public synchronized void releaseAll(long now, Injector injector) {
        closed = true;
        // Every key matters: Android's combination recognizer also remembers ordinary letter keys.
        java.util.Iterator<Press> iterator = pressed.values().iterator();
        while (iterator.hasNext()) {
            Press press = iterator.next();
            try {
                if (injector.inject(UP, press.keycode, 0, 0, press.displayId, press.downTime, now, CANCELED)) {
                    iterator.remove();
                }
            } catch (RuntimeException ignored) {
                // Still release the remaining keys. A later cleanup call can retry failures.
            }
        }
    }
}
