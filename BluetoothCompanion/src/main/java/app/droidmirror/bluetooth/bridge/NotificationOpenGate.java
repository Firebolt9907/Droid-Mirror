package app.droidmirror.bluetooth.bridge;

/** A deferred open is valid only for the original notification and authenticated session. */
public final class NotificationOpenGate {
    public enum Decision { WAIT, OPEN, REJECT }
    private final long deadline;
    private boolean finished;

    public NotificationOpenGate(long now) { deadline = now + 30_000; }

    public Decision poll(long now, boolean locked, boolean authorized, boolean current) {
        return poll(now, locked, true, authorized, current);
    }

    public Decision poll(long now, boolean locked, boolean ready, boolean authorized, boolean current) {
        if (finished || now >= deadline || !authorized || !current) {
            finished = true;
            return Decision.REJECT;
        }
        if (locked || !ready) return Decision.WAIT;
        finished = true;
        return Decision.OPEN;
    }
}
