package app.droidmirror.bluetooth;

import java.util.LinkedHashMap;

/** Small ACK window allows 15 fps without unbounded latency on a slow BLE link. */
public final class CameraFrameWindow {
    public static final int MAX_FRAMES = 3;
    public static final long ACK_TIMEOUT_MS = 3000;
    // Allow timestamp rounding/jitter at the nominal 66.7 ms camera cadence.
    public static final long MIN_FRAME_INTERVAL_MS = 60;
    private final LinkedHashMap<Integer, Long> pending = new LinkedHashMap<>();

    public boolean available(long now) {
        pending.entrySet().removeIf(entry -> now - entry.getValue() >= ACK_TIMEOUT_MS);
        return pending.size() < MAX_FRAMES;
    }
    public void sent(int frame, long now) {
        if (!available(now) || pending.containsKey(frame)) throw new IllegalStateException("Camera window full or duplicate frame");
        pending.put(frame, now);
    }
    public void acknowledge(int frame) { pending.remove(frame); }
    public void clear() { pending.clear(); }
}
