import app.droidmirror.bluetooth.LeftBehindBeaconState;
public final class LeftBehindBeaconStateTest {
    static void check(boolean value) { if (!value) throw new AssertionError(); }
    public static void main(String[] args) {
        LeftBehindBeaconState s = new LeftBehindBeaconState();
        s.motion(0); s.observation(false, 0); s.observation(false, 60_000);
        check(!s.eligible(60_000)); // Never arm on an absent beacon.
        s.observation(true, 70_000); s.motion(80_000); s.observation(false, 80_000);
        check(!s.eligible(140_000)); // Two completed misses, not just elapsed time.
        s.observation(false, 140_000); check(s.eligible(140_000));
        check(s.eligible(140_000)); // Permission failure must not consume the alert.
        s.delivered(); check(!s.eligible(150_000));
        s.observation(true, 160_000); s.observation(false, 170_000); s.observation(false, 200_000);
        s.motion(200_000); check(!s.eligible(214_999)); check(s.eligible(215_000));
        s.unavailable(); check(!s.eligible(215_000));
        s.observation(false, 220_000); check(!s.eligible(280_000));
        s.observation(false, 280_000); s.motion(280_000); check(s.eligible(280_000));
        check(!s.eligible(400_001)); // Stale movement.
        s.motion(900_000); check(!s.eligible(900_000)); // Expired separation.
        s.reset(); s.motion(1_000_000); check(!s.eligible(1_000_000));
        System.out.println("PASS: retained #2 policy, warmup, misses, unavailable, deduplication, timing and expiry");
    }
}
