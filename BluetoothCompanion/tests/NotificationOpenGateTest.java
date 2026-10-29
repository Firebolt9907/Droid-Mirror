import app.droidmirror.bluetooth.bridge.NotificationOpenGate;
import static app.droidmirror.bluetooth.bridge.NotificationOpenGate.Decision.*;

public final class NotificationOpenGateTest {
    public static void main(String[] args) {
        NotificationOpenGate gate = new NotificationOpenGate(1000);
        check(gate.poll(1000, true, true, true) == WAIT, "Locked phone must not open");
        check(gate.poll(2000, true, true, true) == WAIT, "Wait through unlock UI");
        check(gate.poll(2500, false, true, true) == OPEN, "Open after unlock");
        check(gate.poll(2600, false, true, true) == REJECT, "Never open twice");
        check(new NotificationOpenGate(1000).poll(1000, false, true, true) == OPEN, "Unlocked phone opens immediately");
        gate = new NotificationOpenGate(1000);
        check(gate.poll(1000, true, true, true) == WAIT, "Start waiting");
        check(gate.poll(2000, false, false, true) == REJECT, "Disconnect/re-pair cancels open");
        check(gate.poll(2500, false, true, true) == REJECT, "Reconnect cannot revive old open");
        check(new NotificationOpenGate(1000).poll(2000, false, true, false) == REJECT, "Removed or replaced notification must not open");
        gate = new NotificationOpenGate(1000);
        check(gate.poll(30999, true, true, true) == WAIT, "Wait within deadline");
        check(gate.poll(31000, false, true, true) == REJECT, "Unlock at expiry must not open");
        gate = new NotificationOpenGate(1000);
        check(gate.poll(1000, false, false, true, true) == WAIT, "Wait for bridge binding before consuming click");
        check(gate.poll(1200, false, true, true, true) == OPEN, "Open once bridge is ready");
        check(gate.poll(1400, false, true, true, true) == REJECT, "Bridge readiness must not resend an open");
        gate = new NotificationOpenGate(1000);
        check(gate.poll(1000, false, false, true, true) == WAIT, "Bridge can be temporarily unavailable");
        check(gate.poll(1200, false, false, false, true) == REJECT, "Lost authentication cancels bridge wait");
        check(new NotificationOpenGate(1000).poll(31000, false, false, true, true) == REJECT,
            "Bridge wait shares the bounded unlock deadline");
        System.out.println("Notification unlock, stale action, session loss, timeout and single-open tests passed");
    }
    private static void check(boolean condition, String message) {
        if (!condition) throw new AssertionError(message);
    }
}
