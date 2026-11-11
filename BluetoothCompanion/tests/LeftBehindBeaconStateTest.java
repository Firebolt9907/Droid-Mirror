import app.droidmirror.bluetooth.LeftBehindBeaconState;
public final class LeftBehindBeaconStateTest {
    static void check(boolean value) { if (!value) throw new AssertionError(); }
    public static void main(String[] args) {
        LeftBehindBeaconState s = new LeftBehindBeaconState(LeftBehindBeaconState.FAST);
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
        LeftBehindBeaconState balanced = new LeftBehindBeaconState();
        balanced.observation(true, 0); balanced.motion(0);
        balanced.observation(false, 20_000); balanced.observation(false, 80_000);
        check(!balanced.eligible(80_000)); // The old false-alert trigger is insufficient by default.
        balanced.observation(false, 140_000);
        check(balanced.eligible(140_000)); // A single initial motion event permits the third scan.
        balanced.observation(true, 145_000); // Even a weak received beacon cancels all accumulated absence.
        check(!balanced.eligible(145_000));
        check(balanced.moving(240_000)); check(!balanced.moving(240_001));
        balanced.observation(false, 150_000); balanced.observation(false, 210_000);
        balanced.unavailable(); balanced.motion(270_000); balanced.observation(false, 270_000);
        check(!balanced.eligible(330_000)); // Local unavailability cannot complete a miss streak.
        LeftBehindBeaconState cautious = new LeftBehindBeaconState(LeftBehindBeaconState.CONSERVATIVE);
        cautious.observation(true, 0);
        cautious.motion(0);
        for (int i = 0; i < 4; i++) cautious.observation(false, 20_000 + i * 60_000);
        check(!cautious.eligible(259_999));
        cautious.observation(false, 260_000); check(cautious.eligible(260_000));
        check(cautious.moving(360_000)); check(!cautious.moving(360_001));
        cautious.configure(LeftBehindBeaconState.FAST); check(!cautious.eligible(260_000)); // Fresh evidence after changes.
        check(LeftBehindBeaconState.normalize(999) == LeftBehindBeaconState.BALANCED);
        System.out.println("PASS: Fast/Balanced/Conservative thresholds, evidence reset, warmup, deduplication and expiry");
    }
}
