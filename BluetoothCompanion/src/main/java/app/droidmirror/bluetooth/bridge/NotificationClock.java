package app.droidmirror.bluetooth.bridge;

/** Preserve the timer deadline while its notification waits for BLE transmission. */
public final class NotificationClock {
    public static long offsetAtSend(long sampledOffset, long sampledAt, long sentAt) {
        return sampledOffset - Math.max(0, sentAt - sampledAt);
    }
    private NotificationClock() {}
}
