package app.droidmirror.bluetooth;

import java.util.function.LongSupplier;

/** Recovery state machine; runs in the shell user service, never in the capture app. */
public final class DisplayLease {
    public interface Power { void set(boolean on) throws Exception; }
    public static final long TIMEOUT_MS = 2000;
    private final Power power;
    private final LongSupplier clock;
    private Object owner;
    private long lastHeartbeat;
    private boolean restoreNeeded;
    private String error = "";

    public DisplayLease(Power power, LongSupplier clock) { this.power = power; this.clock = clock; }
    public synchronized boolean acquire(Object token) {
        if (token == null || owner != null || restoreNeeded) return false;
        try {
            // Resolve all display tokens and test the restoration API before OFF.
            power.set(true);
            owner = token;
            restoreNeeded = true; // Record recovery intent before any partial OFF.
            lastHeartbeat = clock.getAsLong();
            power.set(false);
            error = "";
            return true;
        } catch (Exception failure) {
            error = "Display power unavailable (" + failure.getClass().getSimpleName() + ")";
            if (restoreNeeded) restore();
            return false;
        }
    }
    public synchronized boolean heartbeat(Object token) {
        tick(); // A late heartbeat must not resurrect an expired lease.
        if (owner == null || owner != token) return false;
        lastHeartbeat = clock.getAsLong();
        return true;
    }
    public synchronized boolean release(Object token) {
        if (owner != token || owner == null) return !restoreNeeded;
        return restore();
    }
    public synchronized void tick() {
        if (owner != null && clock.getAsLong() - lastHeartbeat >= TIMEOUT_MS) {
            restore();
        } else if (restoreNeeded && owner == null) {
            restore(); // Retry failed ON operations, even after the app is dead.
        }
    }
    public synchronized boolean recover() { restoreNeeded = true; return restore(); }
    private boolean restore() {
        owner = null; // Invalidate first: heartbeats cannot switch the panel off again.
        try {
            power.set(true);
            restoreNeeded = false;
            return true;
        } catch (Exception failure) {
            restoreNeeded = true;
            error = "Display restoration failed; retrying (" + failure.getClass().getSimpleName() + ")";
            return false;
        }
    }
    public synchronized boolean owns(Object token) { return owner != null && owner == token; }
    public synchronized boolean isRestoreNeeded() { return restoreNeeded; }
    public synchronized String getLastError() { return error; }
}
