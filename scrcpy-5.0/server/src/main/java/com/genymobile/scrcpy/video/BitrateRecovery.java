package com.genymobile.scrcpy.video;

/** Increase quality after sustained healthy delivery; back off when frames fall behind. */
public final class BitrateRecovery {
    private final int target;
    private final int floor;
    private final long recoveryIntervalUs;
    private int current;
    private long healthySince = -1;
    private long lastFrame = -1;
    private long lastDecrease = Long.MIN_VALUE;

    public BitrateRecovery(int target) { this(target, target, 10000000); }

    /** Probe available bandwidth above startup quality without raising the congestion floor. */
    public BitrateRecovery(int initial, int ceiling, long recoveryIntervalUs) {
        if (initial <= 0 || ceiling < initial || recoveryIntervalUs <= 0) throw new IllegalArgumentException();
        target = ceiling; current = initial;
        floor = Math.min(initial, Math.max(32000, initial / 2));
        this.recoveryIntervalUs = recoveryIntervalUs;
    }

    public int stalled() {
        healthySince = lastFrame = -1;
        current = Math.min(target, Math.max(floor, current / 2));
        return current;
    }

    /** Reduce before the codec queue needs destructive keyframe recovery. */
    public int backlogged(long nowUs) {
        healthySince = lastFrame = -1;
        if (lastDecrease == Long.MIN_VALUE || nowUs - lastDecrease >= 1000000) {
            current = Math.min(target, Math.max(floor, current - Math.max(1, current / 4)));
            lastDecrease = nowUs;
        }
        return current;
    }

    public int healthy(long nowUs) {
        if (lastFrame < 0 || nowUs - lastFrame > 1000000 || nowUs < lastFrame) healthySince = nowUs;
        lastFrame = nowUs;
        if (current < target && nowUs - healthySince >= recoveryIntervalUs) {
            current = Math.min(target, current + Math.max(1, current / 4));
            healthySince = nowUs;
        }
        return current;
    }
}
