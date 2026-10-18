import com.genymobile.scrcpy.video.FrameFreshness;

public final class FrameFreshnessTest {
    private static void require(boolean value) { if (!value) throw new AssertionError(); }
    public static void main(String[] args) {
        FrameFreshness policy = new FrameFreshness(app.droidmirror.bluetooth.HevcCapturePolicy.BLUETOOTH_MAX_FRAME_AGE_US);
        require(policy.shouldSend(1000000, 1100000, false, false));
        require(!policy.shouldSend(1000000, 2000000, false, false));
        require(policy.takeSyncRequest()); require(!policy.takeSyncRequest());
        require(!policy.shouldSend(1000000, 2000000, false, true)); // Old IDR cannot recover latency.
        require(!policy.takeSyncRequest());
        require(policy.shouldSend(0, 2000000, true, false)); // Retain codec configuration.
        require(!policy.shouldSend(2000000, 2100000, false, false)); // Missing reference frames.
        require(policy.shouldSend(2000000, 2100000, false, true));
        require(policy.shouldSend(2100000, 2200000, false, false));
        require(!policy.shouldSend(2200000, 3000000, false, false));
        require(policy.takeSyncRequest());
        // Model five seconds of queued Wi-Fi video. Do not replay historical
        // references, and retry when the first requested IDR also arrives late.
        FrameFreshness wifi = new FrameFreshness(app.droidmirror.bluetooth.HevcCapturePolicy.WIFI_MAX_FRAME_AGE_US);
        require(!wifi.shouldSend(1000000, 6000000, false, false));
        require(wifi.takeSyncRequest());
        require(!wifi.shouldSend(1100000, 6100000, false, false));
        require(!wifi.takeSyncRequest());
        require(!wifi.shouldSend(1200000, 6500000, false, true));
        require(wifi.takeSyncRequest());
        require(wifi.shouldSend(0, 6600000, true, false));
        require(!wifi.shouldSend(6900000, 7000000, false, false));
        require(wifi.takeSyncRequest()); // Even fresh P frames still need a new IDR.
        require(wifi.shouldSend(7100000, 7200000, false, true));
        require(!wifi.takeSyncRequest());
        require(wifi.shouldSend(7200000, 7300000, false, false));
        System.out.println("FrameFreshness: old frames discarded, one sync request, config retained, safe keyframe recovery passed");
    }
}
