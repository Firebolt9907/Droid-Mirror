package app.droidmirror.bluetooth;

/** The selected passive beacon policy (original experiment #2), using monotonic time. */
public final class LeftBehindBeaconState {
    private boolean armed, notified;
    private long absentAt = -1, motionAt = -120_001;
    private int misses;
    public void reset() { armed = notified = false; absentAt = -1; misses = 0; motionAt = -120_001; }
    public void motion(long now) { motionAt = now; }
    public boolean moving(long now) { return now >= motionAt && now - motionAt <= 120_000; }
    public void observation(boolean present, long now) {
        if (present) { armed = true; notified = false; absentAt = -1; misses = 0; }
        else if (armed) { if (absentAt < 0) absentAt = now; misses++; }
    }
    public void unavailable() { misses = 0; absentAt = -1; }
    public boolean eligible(long now) {
        long age = now - absentAt;
        return armed && !notified && absentAt >= 0 && misses >= 2 && moving(now) && age >= 45_000 && age <= 600_000;
    }
    public boolean notified() { return notified; }
    public void delivered() { notified = true; }
}
