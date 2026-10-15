package app.droidmirror.bluetooth;

import java.io.IOException;

/** Bounds radio backlog using the Mac's cumulative video byte acknowledgements. */
public final class VideoWindow {
    private final int capacity;
    private final long timeoutMillis;
    private long sent, acknowledged;
    private boolean closed;
    public VideoWindow(int capacity, long timeoutMillis) {
        if (capacity <= 0 || timeoutMillis <= 0) throw new IllegalArgumentException();
        this.capacity = capacity; this.timeoutMillis = timeoutMillis;
    }
    public synchronized void reserve(int count) throws IOException {
        if (count <= 0 || count > capacity) throw new IOException("Invalid video reservation");
        long deadline = System.nanoTime() + timeoutMillis * 1_000_000;
        while (!closed && sent - acknowledged + count > capacity) {
            long remaining = deadline - System.nanoTime();
            if (remaining <= 0) throw new IOException("Mac video acknowledgement stalled");
            try { wait(Math.max(1, remaining / 1_000_000)); }
            catch (InterruptedException error) { Thread.currentThread().interrupt(); throw new IOException(error); }
        }
        if (closed) throw new IOException("Video window closed");
        sent += count;
    }
    public synchronized void acknowledge(long count) throws IOException {
        if (count < acknowledged || count > sent) throw new IOException("Invalid video acknowledgement");
        acknowledged = count; notifyAll();
    }
    public synchronized void close() { closed = true; notifyAll(); }
}
