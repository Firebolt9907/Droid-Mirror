package app.droidmirror.bluetooth;

/** Media-only state saved before exclusive output capture changes the route. */
final class AudioVolumeLease {
    interface Volume {
        int route() throws Exception;
        int lastAudible() throws Exception;
        boolean muted() throws Exception;
        void setVolume(int value) throws Exception;
        void setMuted(boolean value) throws Exception;
    }
    private final Volume device;
    private final int route, volume;
    private final boolean muted;
    private boolean restored;
    AudioVolumeLease(Volume device) throws Exception {
        this.device = device;
        route = device.route(); volume = device.lastAudible(); muted = device.muted();
        if (route == 0 || (route & 0x8000) != 0 || volume < 0) throw new IllegalStateException("Media volume state unavailable");
        // REMOTE_SUBMIX exclusively redirects playback. Do not mute STREAM_MUSIC
        // or set it to zero: that can mute the forwarded audio as well.
    }
    synchronized void restore() throws Exception {
        if (restored) return;
        // A newly connected headset owns its own volume. The old speaker/device
        // index was not changed by us; Android remembers it when that route returns.
        int currentRoute = device.route();
        if ((currentRoute & 0x8000) != 0) throw new IllegalStateException("Output capture route still releasing");
        if (currentRoute == route) {
            if (device.lastAudible() != volume) device.setVolume(volume);
            if (device.muted() != muted) device.setMuted(muted);
        }
        restored = true;
    }
}
