package app.droidmirror.bluetooth;

/** Size the Classic byte window from delivered bytes, not the encoder's requested bitrate. */
public final class BluetoothVideoBudget {
    public static final int MIN_BYTES = 8 * 1024, MAX_BYTES = 64 * 1024;
    private int capacity = MIN_BYTES;
    private long sampleStarted = -1, sampleCount, lastCount, lastProgress = -1;
    private long bytesPerSecond, ackIntervalMillis = 40;

    public void reset(long count) {
        capacity = MIN_BYTES;
        sampleStarted = lastProgress = -1;
        sampleCount = lastCount = count;
        bytesPerSecond = 0; ackIntervalMillis = 40;
    }

    public int acknowledge(long count, long nowMillis) {
        if (count == lastCount) {
            // Idle heartbeats provide no bandwidth evidence. Start a new sample
            // after a pause instead of averaging idle time into the link rate.
            if (lastProgress >= 0 && nowMillis - lastProgress >= 500) reset(count);
            return capacity;
        }
        if (lastProgress >= 0) {
            long gap = Math.max(1, Math.min(250, nowMillis - lastProgress));
            ackIntervalMillis = (ackIntervalMillis * 3 + gap) / 4;
        }
        lastProgress = nowMillis; lastCount = count;
        if (sampleStarted < 0 || nowMillis - sampleStarted > 1500) {
            sampleStarted = nowMillis; sampleCount = count;
            return capacity;
        }
        long elapsed = nowMillis - sampleStarted;
        if (elapsed >= 500) {
            long deliveredRate = (count - sampleCount) * 1000 / elapsed;
            // React to lost bandwidth immediately; smooth upward so a single
            // bunched ACK cannot inflate the window for the next slow interval.
            bytesPerSecond = bytesPerSecond == 0 || deliveredRate < bytesPerSecond
                    ? deliveredRate : (bytesPerSecond * 3 + deliveredRate) / 4;
            // 150 ms of delivered video plus feedback headroom. The margin
            // prevents ACK jitter from starving the radio; the cap bounds bursts.
            long budget = bytesPerSecond * (150 + ackIntervalMillis) * 5 / 4000;
            int desired = (int)Math.max(MIN_BYTES, Math.min(MAX_BYTES, budget));
            capacity = Math.min(desired, capacity + MIN_BYTES);
            sampleStarted = nowMillis; sampleCount = count;
        }
        return capacity;
    }

    public int capacityBytes() { return capacity; }
    public long deliveredBytesPerSecond() { return bytesPerSecond; }
}
