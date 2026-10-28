package app.droidmirror.bluetooth;

/** One policy, four independent radio observations. Times are monotonic milliseconds. */
public final class LeftBehindExperiments {
    public static final String[] NAMES = {
        "Authenticated BLE link", "Mac BLE beacon (passive)", "Mac BLE GATT challenge", "Bluetooth Classic RFCOMM challenge"
    };
    public static final int COUNT = NAMES.length;
    private final boolean[] armed = new boolean[COUNT], fired = new boolean[COUNT];
    private final long[] absentAt = new long[COUNT];
    private final int[] misses = new int[COUNT];
    private long motionAt = -120_001;
    public LeftBehindExperiments() { reset(); }
    public void reset() {
        java.util.Arrays.fill(armed, false);
        java.util.Arrays.fill(fired, false);
        java.util.Arrays.fill(absentAt, -1);
        java.util.Arrays.fill(misses, 0);
        motionAt = -120_001;
    }
    public void present() { observation(0, true, 0); }
    public void disconnected(long now) { observation(0, false, now); }
    public void motion(long now) { motionAt = now; }
    public boolean moving(long now) { return now >= motionAt && now - motionAt <= 120_000; }
    public void observation(int index, boolean present, long now) {
        if (present) {
            armed[index] = true; fired[index] = false; absentAt[index] = -1; misses[index] = 0;
        } else if (armed[index]) {
            if (absentAt[index] < 0) absentAt[index] = now;
            misses[index]++;
        }
    }
    /** Local failures (permission, radio disabled, scan failure) break the miss streak. */
    public void unavailable(int index) { misses[index] = 0; absentAt[index] = -1; }
    public boolean eligible(int index, long now) {
        if (index < 0 || index >= COUNT) throw new IllegalArgumentException("algorithm");
        if (!armed[index] || fired[index] || absentAt[index] < 0 || !moving(now)) return false;
        long age = now - absentAt[index];
        // Active/passive sampled channels need two completed failed rounds, not a timer-only inference.
        return age >= 45_000 && age <= 600_000 && (index == 0 || misses[index] >= 2);
    }
    public boolean notified(int index) { return fired[index]; }
    public void delivered(int index) { fired[index] = true; }
}
