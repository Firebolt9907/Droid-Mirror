package app.droidmirror.bluetooth;
public final class UnlockPinCooldownTest {
    static void check(long actual, long expected) { if (actual != expected) throw new AssertionError(actual + " != " + expected); }
    public static void main(String[] args) {
        check(UnlockPinCooldown.remaining(1000, 1000), 15000);
        check(UnlockPinCooldown.remaining(1000, 15999), 1);
        check(UnlockPinCooldown.remaining(1000, 16000), 0);
        check(UnlockPinCooldown.remaining(1000, 20000), 0);
        check(UnlockPinCooldown.remaining(1000, 999), 0); // Clock reset cannot cause an indefinite pause.
        check(UnlockPinCooldown.remaining(0, 20000), 0); // Old persistent-pause migrations.
        System.out.println("PIN cooldown: 15-second boundary, expiration and legacy/clock-reset recovery passed");
    }
}
