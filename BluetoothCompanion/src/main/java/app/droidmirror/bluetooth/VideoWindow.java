package app.droidmirror.bluetooth;

import java.io.IOException;

/** Bounds radio backlog using the Mac's cumulative video byte acknowledgements. */
public final class VideoWindow {
    private int capacity;
    private final long timeoutMillis;
    private long sent, acknowledged;
    private long waitNanos;
    private boolean closed;
    private boolean wireless;
    private BluetoothVideoBudget bluetoothBudget;
    public static VideoWindow bluetooth(long timeoutMillis) {
        VideoWindow window = new VideoWindow(BluetoothVideoBudget.MIN_BYTES, timeoutMillis);
        window.bluetoothBudget = new BluetoothVideoBudget();
        return window;
    }
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
            long started = System.nanoTime();
            try { wait(Math.max(1, remaining / 1_000_000)); }
            catch (InterruptedException error) { Thread.currentThread().interrupt(); throw new IOException(error); }
            finally { waitNanos += System.nanoTime() - started; }
        }
        if (closed) throw new IOException("Video window closed");
        sent += count;
    }
    public synchronized void acknowledge(long count) throws IOException {
        if (count < acknowledged || count > sent) throw new IOException("Invalid video acknowledgement");
        acknowledged = count;
        if (!wireless && bluetoothBudget != null)
            capacity = bluetoothBudget.acknowledge(count, System.nanoTime() / 1000000);
        notifyAll();
    }
    /** Keep cumulative accounting, but allow Wi-Fi throughput between BLE ACKs. */
    public synchronized void useWirelessCapacity() {
        wireless = true;
        capacity = 2 * 1024 * 1024;
        notifyAll();
    }
    public synchronized long acknowledgedBytes() { return acknowledged; }
    public synchronized void useBluetoothCapacity() {
        wireless = false;
        if (bluetoothBudget != null) bluetoothBudget.reset(acknowledged);
        capacity = BluetoothWire.VIDEO_WINDOW_BYTES;
        notifyAll();
    }
    public synchronized void close() { closed = true; notifyAll(); }
    public synchronized long takeWaitMillis() { long value = waitNanos / 1000000; waitNanos = 0; return value; }
    public synchronized int capacityBytes() { return capacity; }
    public synchronized long deliveredBytesPerSecond() {
        return bluetoothBudget == null || wireless ? 0 : bluetoothBudget.deliveredBytesPerSecond();
    }
    public synchronized long inFlightBytes() { return sent - acknowledged; }
}
