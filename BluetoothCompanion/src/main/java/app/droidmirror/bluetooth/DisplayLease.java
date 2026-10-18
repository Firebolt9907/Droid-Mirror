package app.droidmirror.bluetooth;

import java.util.function.LongSupplier;

/** Recovery state machine; runs in the shell user service, never in the capture app. */
public final class DisplayLease {
    public interface Power {
        default void prepare() throws Exception {}
        void set(boolean on) throws Exception;
    }
    public static final long TIMEOUT_MS = 2000;
    private final Power power;
    private final LongSupplier clock;
    private final Runnable onRestore;
    private Object owner;
    private long lastHeartbeat;
    private long timeout = TIMEOUT_MS;
    private boolean restoreNeeded;
    private String error = "";

    public DisplayLease(Power power, LongSupplier clock) { this(power, clock, null); }
    public DisplayLease(Power power, LongSupplier clock, Runnable onRestore) {
        this.power = power;
        this.clock = clock;
        this.onRestore = onRestore;
    }
    public synchronized boolean acquire(Object token) { return acquire(token, TIMEOUT_MS); }
    public synchronized boolean acquire(Object token, long startupTimeout) {
        if (token == null || owner != null || restoreNeeded || startupTimeout <= 0) return false;
        try {
            // Resolve recovery APIs without visibly turning an idle panel on.
            power.prepare();
            owner = token;
            restoreNeeded = true; // Record recovery intent before any partial OFF.
            power.set(false);
            lastHeartbeat = clock.getAsLong();
            timeout = startupTimeout;
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
        timeout = TIMEOUT_MS;
        return true;
    }
    /** Reapply OFF after Android's asynchronous wake without extending recovery. */
    public synchronized void keepDark(Object token) throws Exception {
        if (owner != token || owner == null) return;
        power.set(false);
    }
    public synchronized boolean release(Object token) {
        if (owner != token || owner == null) return !restoreNeeded;
        return restore();
    }
    public synchronized void tick() {
        if (owner != null && clock.getAsLong() - lastHeartbeat >= timeout) {
            restore();
        } else if (restoreNeeded && owner == null) {
            restore(); // Retry failed ON operations, even after the app is dead.
        }
    }
    public synchronized boolean recover() { restoreNeeded = true; return restore(); }
    private boolean restore() {
        owner = null; // Invalidate first: heartbeats cannot switch the panel off again.
        if (onRestore != null) {
            try { onRestore.run(); } catch (Exception ignored) {}
        }
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
