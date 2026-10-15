import com.genymobile.scrcpy.video.FrameFreshness;

public final class FrameFreshnessTest {
    private static void require(boolean value) { if (!value) throw new AssertionError(); }
    public static void main(String[] args) {
        FrameFreshness policy = new FrameFreshness(500000);
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
        System.out.println("FrameFreshness: old frames discarded, one sync request, config retained, safe keyframe recovery passed");
    }
}
