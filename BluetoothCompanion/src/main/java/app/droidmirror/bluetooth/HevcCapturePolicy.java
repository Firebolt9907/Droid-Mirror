package app.droidmirror.bluetooth;

/** Codec-independent constants used by the hybrid HEVC capture and its wire fixtures. */
public final class HevcCapturePolicy {
    // Prefer current, small frames over detail that the Classic link cannot deliver.
    public static final int BLUETOOTH_SHORT_EDGE = 320;
    public static final int BLUETOOTH_FPS = 15;
    public static final int BLUETOOTH_BIT_RATE = 128000;
    // Recover to startup quality only; avoid upward bandwidth probes on Classic.
    public static final int BLUETOOTH_MAX_BIT_RATE = BLUETOOTH_BIT_RATE;
    public static final long BLUETOOTH_MAX_FRAME_AGE_US = 500000;
    public static final String CODEC = "h265";
    public static final int WIRE_CODEC_ID = 0x68323635;
    public static final String WIFI_OPTIONS = "profile:int=1,max-bframes:int=0";

    private HevcCapturePolicy() {}

    public static int bitRateMode(boolean cbr, boolean vbr) { return cbr ? 2 : vbr ? 1 : -1; }

    public static String bluetoothOptions(int mode, boolean intraRefresh) {
        if (mode!=1 && mode!=2) throw new IllegalArgumentException("HEVC requires bitrate control");
        return "profile:int=1,bitrate-mode:int=" + mode
            + ",frame-rate:int=" + BLUETOOTH_FPS
            + ",max-bframes:int=0,i-frame-interval=60,repeat-previous-frame-after:long=" + ((1000000L + BLUETOOTH_FPS - 1) / BLUETOOTH_FPS)
            + (intraRefresh ? ",intra-refresh-period:int=" + BLUETOOTH_FPS : "");
    }
}
