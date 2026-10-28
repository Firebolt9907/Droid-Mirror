import app.droidmirror.bluetooth.LeftBehindFeedbackEvent;
public final class LeftBehindFeedbackEventTest {
    static void check(boolean value) { if (!value) throw new AssertionError(); }
    public static void main(String[] args) {
        check(LeftBehindFeedbackEvent.choice("correct"));
        check(LeftBehindFeedbackEvent.choice("incorrect"));
        check(!LeftBehindFeedbackEvent.choice("dismissed"));
        check(!LeftBehindFeedbackEvent.choice(null));
        check(LeftBehindFeedbackEvent.elapsed(1000, 8, 124_456, 8) == 123_456);
        check(LeftBehindFeedbackEvent.elapsed(1000, 8, 50, 9) == -1); // Reboot, never guess from wall time.
        check(LeftBehindFeedbackEvent.elapsed(1000, 8, 999, 8) == -1);
        check(LeftBehindFeedbackEvent.elapsed(1000, -1, 2000, -1) == -1); // Unknown boot provenance.
        check(LeftBehindFeedbackEvent.duration(123_456).equals("2m 3s"));
        check(LeftBehindFeedbackEvent.duration(3_661_000).equals("1h 1m 1s"));
        check(LeftBehindFeedbackEvent.duration(0).equals("0s"));
        check(LeftBehindFeedbackEvent.duration(-1).equals("duration unknown"));
        System.out.println("PASS: feedback choices and monotonic notification lifetime, including reboot/unknown time");
    }
}
