import app.droidmirror.bluetooth.DisplayLease;
import java.util.ArrayList;
import java.util.List;
import java.util.concurrent.atomic.AtomicLong;

public final class DisplayLeaseTest {
    static void require(boolean condition) { if (!condition) throw new AssertionError(); }
    static final class Power implements DisplayLease.Power {
        final List<Boolean> calls = new ArrayList<>();
        boolean on = true;
        int failOn;
        boolean failOffAfterChange;
        @Override public void set(boolean value) throws Exception {
            calls.add(value);
            if (value && failOn > 0) { failOn--; throw new Exception("ON failed"); }
            on = value;
            if (!value && failOffAfterChange) throw new Exception("Partial OFF failed");
        }
    }
    public static void main(String[] args) {
        AtomicLong clock = new AtomicLong(1);
        Power power = new Power();
        DisplayLease lease = new DisplayLease(power, clock::get);
        Object owner = new Object(), stranger = new Object();
        require(lease.acquire(owner));
        require(power.calls.equals(List.of(true, false)) && !power.on);
        require(!lease.acquire(stranger));
        require(!lease.heartbeat(stranger));
        require(lease.release(stranger) == false && !power.on);
        clock.set(1001); require(lease.heartbeat(owner));
        clock.set(3000); lease.tick(); require(!power.on);
        clock.set(3001); lease.tick(); require(power.on && !lease.owns(owner));
        require(!lease.heartbeat(owner)); // Cannot resurrect after timeout.
        require(lease.acquire(stranger));
        require(lease.release(owner) == false && !power.on); // Stale death callback cannot end a new lease.
        require(lease.release(stranger) && power.on); // Models explicit stop / Binder death.

        power = new Power(); power.failOn = 1;
        lease = new DisplayLease(power, clock::get);
        require(!lease.acquire(owner) && power.on && !lease.isRestoreNeeded());
        require(power.calls.equals(List.of(true))); // Failed recovery preflight never OFFs.

        power = new Power(); power.failOffAfterChange = true;
        lease = new DisplayLease(power, clock::get);
        require(!lease.acquire(owner) && power.on && !lease.isRestoreNeeded());
        require(power.calls.equals(List.of(true, false, true))); // Partial OFF rolled back.

        power = new Power(); lease = new DisplayLease(power, clock::get);
        require(lease.acquire(owner)); power.failOn = 2;
        require(!lease.release(owner) && !power.on && lease.isRestoreNeeded());
        require(!lease.acquire(stranger));
        lease.tick(); require(lease.isRestoreNeeded());
        lease.tick(); require(power.on && !lease.isRestoreNeeded()); // Retry without any app heartbeat.

        power = new Power(); lease = new DisplayLease(power, clock::get);
        require(lease.acquire(owner)); clock.addAndGet(DisplayLease.TIMEOUT_MS);
        require(!lease.heartbeat(owner) && power.on); // Late heartbeat does not extend an expired lease.
        require(lease.acquire(stranger)); require(lease.recover() && power.on);
        require(!lease.heartbeat(stranger)); // Manual recovery also invalidates the session.
        DisplayLease slow = new DisplayLease(value -> {
            if (!value) clock.addAndGet(3000); // A slow display preparation exceeds the lease duration.
        }, clock::get);
        require(slow.acquire(owner));
        require(slow.heartbeat(owner)); // Preparation time must not consume the active lease.
        clock.addAndGet(DisplayLease.TIMEOUT_MS);
        require(!slow.heartbeat(owner)); // The ordinary recovery deadline still applies afterward.
        System.out.println("DisplayLease: death/stop, timeout, stale tokens, late heartbeat, OFF rollback, ON retries and preflight passed");
    }
}
