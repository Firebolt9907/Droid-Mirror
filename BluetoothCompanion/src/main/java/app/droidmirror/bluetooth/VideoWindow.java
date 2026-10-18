package app.droidmirror.bluetooth;

import java.io.IOException;

/** Bounds radio backlog using the Mac's cumulative video byte acknowledgements. */
public final class VideoWindow {
    private int capacity;
    private final long timeoutMillis;
    private long sent, acknowledged;
    private long waitNanos;
    private long progressNanos = System.nanoTime();
    // Mac detects silent ADB loss after four seconds, then signals over BLE.
    private static final long WIRELESS_RECOVERY_MILLIS = 12000;
    // Every unacknowledged byte must be replayed over Classic after Wi-Fi loss.
    // With 40 ms ACKs this still admits the default 12 Mbps Wi-Fi profile while
    // avoiding megabytes of stale video ahead of the restored Bluetooth encoder.
    public static final int WIRELESS_WINDOW_BYTES = 128 * 1024;
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
        awaitCredit(sent + count, 0);
        sent += count;
    }
    private void awaitCredit(long end, long received) throws IOException {
        long startedWaiting = System.nanoTime();
        while (!closed && end - Math.max(acknowledged, received) > capacity) {
            long timeout = wireless ? Math.max(timeoutMillis, WIRELESS_RECOVERY_MILLIS) : timeoutMillis;
            long remaining = timeout * 1_000_000 - (System.nanoTime() - Math.max(startedWaiting, progressNanos));
            if (remaining <= 0) throw new IOException("Mac video acknowledgement stalled");
            long started = System.nanoTime();
            try { wait(Math.max(1, remaining / 1_000_000)); }
            catch (InterruptedException error) { Thread.currentThread().interrupt(); throw new IOException(error); }
            finally { waitNanos += System.nanoTime() - started; }
        }
        if (closed) throw new IOException("Video window closed");
    }
    /** Replay is already counted in sent; pace it without reserving it twice. */
    public synchronized void awaitBluetoothReplay(long end, long received) throws IOException {
        if (end > sent || received < 0 || received > sent) throw new IOException("Invalid replay offset");
        awaitCredit(end, received);
    }
    public synchronized void acknowledge(long count) throws IOException {
        if (count < acknowledged || count > sent) throw new IOException("Invalid video acknowledgement");
        if (count > acknowledged) progressNanos = System.nanoTime();
        acknowledged = count;
        if (!wireless && bluetoothBudget != null)
            capacity = bluetoothBudget.acknowledge(count, System.nanoTime() / 1000000);
        notifyAll();
    }
    /** Keep cumulative accounting, but allow Wi-Fi throughput between BLE ACKs. */
    public synchronized void useWirelessCapacity() {
        wireless = true;
        progressNanos = System.nanoTime();
        capacity = WIRELESS_WINDOW_BYTES;
        notifyAll();
    }
    public synchronized long acknowledgedBytes() { return acknowledged; }
    public synchronized void useBluetoothCapacity() {
        wireless = false;
        progressNanos = System.nanoTime();
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
