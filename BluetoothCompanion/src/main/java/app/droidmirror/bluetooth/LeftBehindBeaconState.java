package app.droidmirror.bluetooth;

/** The selected passive beacon policy (original experiment #2), using monotonic time. */
public final class LeftBehindBeaconState {
    public static final int FAST = 0, BALANCED = 1, CONSERVATIVE = 2;
    public static final String[] PRESET_NAMES = {"Fast (original)", "Balanced (recommended)", "Conservative"};
    public static final String[] PRESET_DESCRIPTIONS = {
        "2 missing scans; at least 45 seconds after the first miss",
        "3 missing scans; at least 2 minutes after the first miss",
        "5 missing scans; at least 4 minutes after the first miss"
    };
    private int mode = -1;
    private static final int[] REQUIRED_MISSES = {2, 3, 5};
    private static final long[] MIN_ABSENCE = {45_000, 120_000, 240_000};
    private boolean armed, notified;
    public LeftBehindBeaconState() { this(BALANCED); }
    public LeftBehindBeaconState(int mode) { configure(mode); }
    public static int normalize(int value) { return value >= FAST && value <= CONSERVATIVE ? value : BALANCED; }
    public void configure(int value) {
        int selected = normalize(value);
        if (mode != selected) { mode = selected; reset(); }
    }
    public String evidence(long now) {
        if (!armed) return "Waiting to see your Mac nearby before arming";
        if (absentAt < 0) return "No current confirmed absence";
        long age = Math.max(0, now - absentAt);
        if (age > 600_000) return "Old absence expired; waiting to see your Mac nearby again";
        return Math.min(misses, REQUIRED_MISSES[mode]) + "/" + REQUIRED_MISSES[mode] + " missing scans; "
            + (age / 1000) + "/" + (MIN_ABSENCE[mode] / 1000) + " seconds since first miss"
            + (moving(now) ? "; movement within confirmation window" : "; waiting for movement");
    }
    private long absentAt = -1, motionAt = Long.MIN_VALUE / 2;
    private int misses;
    public void reset() { armed = notified = false; absentAt = -1; misses = 0; motionAt = Long.MIN_VALUE / 2; }
    public void motion(long now) { motionAt = now; }
    public boolean moving(long now) {
        // One significant-motion event must allow the longer confirmation to finish;
        // otherwise a 2-minute sampling cutoff can prevent the third/fifth scan entirely.
        long window = mode == FAST ? 120_000 : MIN_ABSENCE[mode] + 120_000;
        return now >= motionAt && now - motionAt <= window;
    }
    public void observation(boolean present, long now) {
        if (present) { armed = true; notified = false; absentAt = -1; misses = 0; }
        else if (armed) { if (absentAt < 0) absentAt = now; misses++; }
    }
    public void unavailable() { misses = 0; absentAt = -1; }
    public boolean eligible(long now) {
        long age = now - absentAt;
        return armed && !notified && absentAt >= 0 && misses >= REQUIRED_MISSES[mode] && moving(now) && age >= MIN_ABSENCE[mode] && age <= 600_000;
    }
    public boolean notified() { return notified; }
    public void delivered() { notified = true; }
}
