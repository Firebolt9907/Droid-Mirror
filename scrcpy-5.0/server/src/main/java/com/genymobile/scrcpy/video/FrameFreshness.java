package com.genymobile.scrcpy.video;

/** Resume only at a current keyframe after discarding stale reference frames. */
public final class FrameFreshness {
    private final long maxAgeUs;
    private boolean waitingForKeyframe;
    private boolean requestSync;
    private long lastSyncUs;
    public FrameFreshness(long maxAgeUs) { this.maxAgeUs = maxAgeUs; }
    public boolean shouldSend(long ptsUs, long nowUs, boolean config, boolean keyframe) {
        if (config) return true;
        boolean stale = nowUs - ptsUs > maxAgeUs;
        if (stale || (waitingForKeyframe && !keyframe)) {
            // A requested IDR may itself age out behind a blocked transport.
            // Retry at a bounded cadence until a current IDR actually arrives.
            if (!waitingForKeyframe || nowUs - lastSyncUs >= maxAgeUs) {
                requestSync = true;
                lastSyncUs = nowUs;
            }
            waitingForKeyframe = true;
            return false;
        }
        waitingForKeyframe = false;
        return true;
    }
    public boolean takeSyncRequest() { boolean value = requestSync; requestSync = false; return value; }
}
