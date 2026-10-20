import com.genymobile.scrcpy.video.VideoStartGate;

public final class VideoStartGateTest {
    static void check(boolean condition) { if (!condition) throw new AssertionError(); }
    public static void main(String[] args) {
        VideoStartGate gate = new VideoStartGate();
        check(gate.shouldSend(0, true, false)); // Warm decoder configuration is safe.
        check(!gate.shouldSend(100, false, true)); // Never send credential UI.
        check(!gate.takeSyncRequest());
        gate.open(1000);
        check(gate.takeSyncRequest() && !gate.takeSyncRequest());
        check(!gate.shouldSend(999, false, true)); // Queued keyguard frames remain private.
        check(!gate.shouldSend(1001, false, false)); // No references to discarded frames.
        check(gate.shouldSend(1002, false, true));
        check(gate.shouldSend(1003, false, false));
        gate.open(5000); // Duplicate unlock callbacks must not interrupt live video.
        check(!gate.takeSyncRequest() && gate.shouldSend(1004, false, false));
        check(!gate.shouldSend(998, false, false));
        System.out.println("VideoStartGate: private warmup, timestamp cutoff, fresh IDR and duplicate callbacks passed");
    }
}
