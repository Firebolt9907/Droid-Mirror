package com.genymobile.scrcpy.video;

/** Resume only at a current keyframe after discarding stale reference frames. */
public final class FrameFreshness {
    private final long maxAgeUs;
    private boolean waitingForKeyframe;
    private boolean requestSync;
    public FrameFreshness(long maxAgeUs) { this.maxAgeUs = maxAgeUs; }
    public boolean shouldSend(long ptsUs, long nowUs, boolean config, boolean keyframe) {
        if (config) return true;
        if (nowUs - ptsUs > maxAgeUs) {
            if (!waitingForKeyframe) requestSync = true;
            waitingForKeyframe = true;
            return false;
        }
        if (waitingForKeyframe && !keyframe) return false;
        waitingForKeyframe = false;
        return true;
    }
    public boolean takeSyncRequest() { boolean value = requestSync; requestSync = false; return value; }
}
