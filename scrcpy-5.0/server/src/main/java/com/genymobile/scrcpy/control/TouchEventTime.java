package com.genymobile.scrcpy.control;

/** Preserve source gesture intervals; network arrival times must not determine fling velocity. */
public final class TouchEventTime {
    private long last = -1;
    public long resolve(long source, long now) {
        if (source == -1) { last = now; return now; } // Standard ADB protocol.
        if (source < 0 || source > now || now - source > 10000) return -1;
        last = Math.max(last, source);
        return last;
    }
}
