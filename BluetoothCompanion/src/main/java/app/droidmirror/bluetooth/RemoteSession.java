package app.droidmirror.bluetooth;

import java.util.function.LongSupplier;

/** Session end policy independent of the app process and display lease. */
public final class RemoteSession {
    public static final int STOP = 1, TIMEOUT = 2, LOCAL_USE = 3, APP_DIED = 4, GUARD_STOP = 5, RECOVERY = 6, UNLOCK_FAILED = 7;
    public interface End { boolean run(Object token, int cause); }
    private final LongSupplier clock;
    private final End end;
    private Object owner;
    private long lastHeartbeat;
    private long timeout = DisplayLease.TIMEOUT_MS;
    public RemoteSession(LongSupplier clock, End end) { this.clock = clock; this.end = end; }
    public synchronized boolean begin(Object token) { return begin(token, DisplayLease.TIMEOUT_MS); }
    public synchronized boolean begin(Object token, long startupTimeout) {
        if (token == null || owner != null || startupTimeout <= 0) return false;
        owner = token; timeout = startupTimeout; lastHeartbeat = clock.getAsLong(); return true;
    }
    public synchronized boolean heartbeat(Object token) {
        expire();
        if (owner != token || owner == null) return false;
        lastHeartbeat = clock.getAsLong(); timeout = DisplayLease.TIMEOUT_MS; return true;
    }
    public synchronized void tick(boolean interactive) {
        if (owner != null && !interactive) finish(owner, LOCAL_USE);
        else expire();
    }
    private void expire() {
        if (owner != null && clock.getAsLong() - lastHeartbeat >= timeout) finish(owner, TIMEOUT);
    }
    public synchronized boolean finish(Object token, int cause) {
        if (owner == null || owner != token) return false;
        owner = null; // Commit before side effects: reentrant/death/end calls cannot notify twice.
        return end.run(token, cause);
    }
    public synchronized boolean owns(Object token) { return owner != null && owner == token; }
    public synchronized Object owner() { return owner; }
}
