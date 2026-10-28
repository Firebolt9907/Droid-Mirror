import app.droidmirror.bluetooth.bridge.NotificationClock;

public final class NotificationClockTest {
    private static void check(long expected, long actual) {
        if (expected != actual) throw new AssertionError(expected + " != " + actual);
    }
    public static void main(String[] args) {
        check(132000, NotificationClock.offsetAtSend(140000, 100000, 108000));
        check(-28000, NotificationClock.offsetAtSend(-20000, 100000, 108000));
        check(-6000, NotificationClock.offsetAtSend(2000, 100000, 108000));
        check(140000, NotificationClock.offsetAtSend(140000, 100000, 100000));
        check(140000, NotificationClock.offsetAtSend(140000, 100000, 99000));
        System.out.println("Notification timer queue-age tests passed");
    }
}
