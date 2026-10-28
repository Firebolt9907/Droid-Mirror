import app.droidmirror.bluetooth.LeftBehindExperiments;

public final class LeftBehindExperimentsTest {
    static void check(boolean value) { if (!value) throw new AssertionError(); }
    static void none(LeftBehindExperiments s, long now) {
        for (int i = 0; i < LeftBehindExperiments.COUNT; i++) check(!s.eligible(i, now));
    }
    public static void main(String[] args) {
        LeftBehindExperiments s = new LeftBehindExperiments();
        s.motion(1000);
        for (int i = 0; i < 4; i++) { s.observation(i, false, 0); s.observation(i, false, 60_000); }
        none(s, 60_000); // Each channel must first prove that it works nearby.
        for (int i = 0; i < 4; i++) s.observation(i, true, 70_000);
        s.motion(80_000);
        for (int i = 0; i < 4; i++) s.observation(i, false, 80_000);
        none(s, 124_999);
        check(s.eligible(0, 125_000));
        for (int i = 1; i < 4; i++) check(!s.eligible(i, 125_000)); // One failed round is insufficient.
        for (int i = 1; i < 4; i++) s.observation(i, false, 140_000);
        for (int i = 0; i < 4; i++) check(s.eligible(i, 140_000));
        s.delivered(1); check(!s.eligible(1, 140_000)); check(s.eligible(2, 140_000));
        s.observation(2, true, 150_000); check(!s.eligible(2, 150_000));
        check(s.eligible(3, 150_000)); // GATT success does not mask Classic absence.
        s.unavailable(3); check(!s.eligible(3, 150_000));
        s.observation(3, false, 160_000); check(!s.eligible(3, 205_000));
        s.motion(210_000); s.observation(3, false, 220_000); check(s.eligible(3, 220_000));
        none(s, 400_000); // Stale motion.
        s.motion(900_000); none(s, 900_000); // Old separation expires.
        s.observation(1, true, 901_000); s.observation(1, false, 902_000); s.observation(1, false, 962_000);
        check(s.eligible(1, 962_000)); // Reconnection rearms that channel only.
        s.reset(); s.motion(1_000_000); none(s, 1_000_000);
        System.out.println("LeftBehindExperiments tests passed (4 independent radio channels)");
    }
}
