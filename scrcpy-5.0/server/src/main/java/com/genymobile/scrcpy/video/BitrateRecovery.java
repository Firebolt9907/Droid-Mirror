package com.genymobile.scrcpy.video;

/** Restore the configured quality after ten seconds of continuous healthy output. */
public final class BitrateRecovery {
    private final int target;
    private int current;
    private long healthySince = -1;
    private long lastFrame = -1;
    private long lastDecrease = Long.MIN_VALUE;

    public BitrateRecovery(int target) { this.target = target; current = target; }

    public int stalled() {
        healthySince = lastFrame = -1;
        current = Math.min(target, Math.max(Math.max(32000, target / 2), current / 2));
        return current;
    }

    /** Reduce before the codec queue needs destructive keyframe recovery. */
    public int backlogged(long nowUs) {
        healthySince = lastFrame = -1;
        if (lastDecrease == Long.MIN_VALUE || nowUs - lastDecrease >= 1000000) {
            current = Math.min(target, Math.max(Math.max(32000, target / 2), current - Math.max(1, current / 4)));
            lastDecrease = nowUs;
        }
        return current;
    }

    public int healthy(long nowUs) {
        if (lastFrame < 0 || nowUs - lastFrame > 1000000 || nowUs < lastFrame) healthySince = nowUs;
        lastFrame = nowUs;
        if (current < target && nowUs - healthySince >= 10000000) {
            current = Math.min(target, current + Math.max(1, current / 4));
            healthySince = nowUs;
        }
        return current;
    }
}
