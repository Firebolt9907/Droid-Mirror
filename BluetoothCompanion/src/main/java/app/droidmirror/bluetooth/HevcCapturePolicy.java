package app.droidmirror.bluetooth;

/** Codec-independent constants used by the hybrid HEVC capture and its wire fixtures. */
public final class HevcCapturePolicy {
    public static final String CODEC = "h265";
    public static final int WIRE_CODEC_ID = 0x68323635;
    public static final String WIFI_OPTIONS = "profile:int=1,max-bframes:int=0";

    private HevcCapturePolicy() {}

    public static int bitRateMode(boolean cbr, boolean vbr) { return cbr ? 2 : vbr ? 1 : -1; }

    public static String bluetoothOptions(int mode, boolean intraRefresh) {
        if (mode!=1 && mode!=2) throw new IllegalArgumentException("HEVC requires bitrate control");
        return "profile:int=1,bitrate-mode:int=" + mode
            + ",frame-rate:int=16,max-bframes:int=0,i-frame-interval=60,repeat-previous-frame-after:long=62500"
            + (intraRefresh ? ",intra-refresh-period:int=16" : "");
    }
}
