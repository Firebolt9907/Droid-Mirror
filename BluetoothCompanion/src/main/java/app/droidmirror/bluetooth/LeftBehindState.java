package app.droidmirror.bluetooth;

/** Monotonic-time separation policy. State deliberately does not survive process restarts. */
public final class LeftBehindState {
    public static final long GRACE_MS = 45_000;
    public static final long MOTION_WINDOW_MS = 120_000;
    public static final long MAX_ABSENCE_MS = 600_000;
    private boolean armed, absent, notified;
    private long disconnectedAt, motionAt = -MOTION_WINDOW_MS;

    public void present() { armed = true; absent = false; notified = false; }
    public void disconnected(long now) {
        if (armed && !absent) { absent = true; disconnectedAt = now; }
    }
    public void motion(long now) { if (armed) motionAt = now; }
    public void reset() { armed = absent = notified = false; motionAt = -MOTION_WINDOW_MS; }
    public boolean shouldNotify(long now) {
        if (!armed || !absent || notified) return false;
        long elapsed = now - disconnectedAt;
        if (elapsed > MAX_ABSENCE_MS) { reset(); return false; }
        if (elapsed < GRACE_MS || now - motionAt > MOTION_WINDOW_MS) return false;
        notified = true;
        return true;
    }
}
