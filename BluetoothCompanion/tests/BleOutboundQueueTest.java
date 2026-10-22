import app.droidmirror.bluetooth.bridge.BleOutboundQueue;

public final class BleOutboundQueueTest {
    private static void check(boolean value) { if (!value) throw new AssertionError(); }
    public static void main(String[] args) {
        BleOutboundQueue queue = new BleOutboundQueue();
        check(queue.append("bulk0", true, 0));
        check(queue.append("bulk1", true, 0));
        for (int i = 0; i < 8; i++) check(queue.append("control" + i, false, 0));
        for (int i = 0; i < 4; i++) check(queue.next(1).equals("control" + i));
        check(queue.next(1).equals("bulk0"));
        for (int i = 4; i < 8; i++) check(queue.next(1).equals("control" + i));
        check(queue.next(1).equals("bulk1"));
        check(queue.getBytes() == 0 && queue.next(1) == null);
        check(queue.append("snapshot", false, 0));
        check(queue.append("removed", false, 0));
        check(queue.append("pong", false, 0, true));
        check(queue.next(1).equals("pong"));
        check(queue.next(1).equals("snapshot"));
        check(queue.next(1).equals("removed"));
        check(queue.append("expired", false, 0));
        check(queue.next(60000) == null && queue.getBytes() == 0);
        check(queue.append("new0", false, 60001));
        check(queue.append("new1", false, 60001));
        check(queue.next(60002).equals("new0"));
        check(queue.next(60002).equals("new1"));
        check(queue.next(60002) == null && queue.getBytes() == 0);
        check(!queue.append("x".repeat(5801), false, 0));
        int count = 0;
        while (queue.append("x".repeat(4096), true, 0)) count++;
        check(count > 0 && queue.getBytes() <= 262144);
        check(queue.next(60000) == null && queue.getBytes() == 0);
        System.out.println("PASS: Android bounded plaintext queue, deadlines, control latency and bulk fairness");
    }
}
