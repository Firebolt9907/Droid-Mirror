import app.droidmirror.bluetooth.WriteDeadline;
import java.util.concurrent.atomic.AtomicLong;
public final class WriteDeadlineTest {
    public static void main(String[] args) {
        AtomicLong now = new AtomicLong();
        WriteDeadline deadline = new WriteDeadline(now::get);
        if (deadline.expired(1000)) throw new AssertionError("Idle writer expired");
        deadline.begin(); now.set(1001);
        if (!deadline.expired(1000)) throw new AssertionError("Blocked write not detected");
        deadline.end(); now.set(999999);
        if (deadline.expired(1000)) throw new AssertionError("Cleared timestamp treated as a stall");
        WriteDeadline[] racing = new WriteDeadline[1];
        AtomicLong calls = new AtomicLong();
        racing[0] = new WriteDeadline(() -> {
            if (calls.incrementAndGet() == 2) racing[0].end();
            return calls.get() == 1 ? 0 : 1001;
        });
        racing[0].begin();
        if (racing[0].expired(1000)) throw new AssertionError("Completed concurrent write was cancelled");
        deadline.begin(); now.addAndGet(500);
        if (deadline.expired(1000)) throw new AssertionError("New write inherited an old deadline");
        System.out.println("WriteDeadline: idle, genuine stall, cleared timestamp, concurrent completion and replacement passed");
    }
}
