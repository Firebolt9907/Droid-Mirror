package app.droidmirror.bluetooth;

/** Profiles change only when the authenticated video lane changes. */
public enum CameraVideoProfile {
    BLUETOOTH(320, 240, 15, 128000, 0),
    WIFI(1280, 720, 30, 3000000, 1);
    public final int width, height, fps, bitRate, keyframeSeconds;
    CameraVideoProfile(int width, int height, int fps, int bitRate, int keyframeSeconds) {
        this.width = width; this.height = height; this.fps = fps;
        this.bitRate = bitRate; this.keyframeSeconds = keyframeSeconds;
    }
    public static CameraVideoProfile forTransport(boolean authenticatedIP) {
        return authenticatedIP ? WIFI : BLUETOOTH;
    }
}
