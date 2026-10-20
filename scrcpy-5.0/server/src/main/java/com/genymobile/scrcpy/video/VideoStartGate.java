package com.genymobile.scrcpy.video;

/** Warm the encoder without publishing credential UI or queued pre-unlock frames. */
public final class VideoStartGate {
    private boolean open;
    private long earliestPtsUs;
    private boolean waitingForKeyframe = true;
    private boolean requestSync;

    public synchronized void open(long nowUs) {
        if (open) return;
        earliestPtsUs = nowUs;
        requestSync = true;
        open = true;
    }
    public synchronized boolean takeSyncRequest() {
        boolean requested = requestSync; requestSync = false; return requested;
    }
    public synchronized boolean shouldSend(long ptsUs, boolean config, boolean keyframe) {
        if (config) return true; // Decoder configuration contains no captured pixels.
        if (!open || ptsUs < earliestPtsUs) return false;
        if (waitingForKeyframe) {
            if (!keyframe) return false;
            waitingForKeyframe = false;
        }
        return true;
    }
}
