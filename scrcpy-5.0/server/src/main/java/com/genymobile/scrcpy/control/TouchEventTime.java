package com.genymobile.scrcpy.control;

/** Preserve source gesture intervals; network arrival times must not determine fling velocity. */
public final class TouchEventTime {
    private long last = -1;
    private long gestureOffset;
    private boolean gestureAnchored;
    /** Allow at most 100 ms of backdating for a delayed DOWN. This leaves room
     * for buffered movement samples without expiring a long-press deadline.
     * Anchoring DOWN to delivery itself collapses a buffered flick to zero time. */
    public long resolveGesture(long source, long now, boolean begin) {
        if (source == -1) return resolve(source, now);
        if (source < 0 || source > now || now - source > 10000) return -1;
        if (begin) {
            gestureOffset = Math.max(0, now - source - 100);
            gestureAnchored = true;
        }
        if (!gestureAnchored) return resolve(source, now);
        long mapped = Math.min(now, source + gestureOffset);
        last = Math.max(last, mapped);
        return last;
    }
    public long resolve(long source, long now) {
        if (source == -1) { last = now; return now; } // Standard ADB protocol.
        if (source < 0 || source > now || now - source > 10000) return -1;
        last = Math.max(last, source);
        return last;
    }
}
