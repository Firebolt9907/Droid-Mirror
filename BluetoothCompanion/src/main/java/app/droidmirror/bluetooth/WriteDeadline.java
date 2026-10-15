package app.droidmirror.bluetooth;

import java.util.function.LongSupplier;

/** A deadline belongs to one active write, never to a cleared/replaced timestamp. */
public final class WriteDeadline {
    private static final class Write {
        final long started;
        Write(long started) { this.started = started; }
    }
    private final LongSupplier clock;
    private volatile Write active;
    public WriteDeadline(LongSupplier clock) { this.clock = clock; }
    public void begin() { active = new Write(clock.getAsLong()); }
    public void end() { active = null; }
    public boolean expired(long timeout) {
        Write write = active;
        return write != null && clock.getAsLong() - write.started > timeout && active == write;
    }
}
