package app.droidmirror.bluetooth;

import java.io.*;
import java.nio.charset.StandardCharsets;

/** Versioned envelope: video remains scrcpy 5, control events never reach its decoder. */
public final class BluetoothWire {
    public static final byte[] MAGIC = "DMBT0005".getBytes(StandardCharsets.US_ASCII);
    public static final int VIDEO = 0, EVENT = 1, MAX_CHUNK = 16 * 1024, VIDEO_CHUNK = 1024;
    public static final int PHONE_ON = 1, SESSION_ENDED = 2, LOCAL_USE_FAILED = 3, STREAM_STARTED = 4, CAPTURE_FAILED = 5, ALIVE = 6;
    private final DataOutputStream out;
    private final WriteDeadline deadline;
    private VideoWindow videoWindow;
    public BluetoothWire(OutputStream stream) throws IOException {
        this(stream, () -> System.nanoTime() / 1_000_000);
    }
    public BluetoothWire(OutputStream stream, java.util.function.LongSupplier clock) throws IOException {
        deadline = new WriteDeadline(clock);
        // Coalesce the envelope
        // header and payload rather than sending five tiny header packets.
        out = new DataOutputStream(new BufferedOutputStream(stream, MAX_CHUNK + 5));
        out.write(MAGIC); out.flush();
    }
    public boolean writeStalled(long peerAge) { return peerAge > 5000 && deadline.expired(5000); }
    public void setVideoWindow(VideoWindow window) { videoWindow = window; }
    public synchronized void bleSetup(byte[] key) throws IOException {
        if (key.length != 32) throw new IOException("Invalid BLE session key");
        out.writeByte(3); out.writeInt(32); out.write(key); out.flush();
    }
    public void video(byte[] bytes) throws IOException {
        for (int offset = 0; offset < bytes.length; offset += VIDEO_CHUNK) {
            int length = Math.min(VIDEO_CHUNK, bytes.length - offset);
            if (videoWindow != null) videoWindow.reserve(length);
            synchronized (this) {
                deadline.begin();
                try { out.writeByte(VIDEO); out.writeInt(length); out.write(bytes, offset, length); out.flush(); }
                finally { deadline.end(); }
            }
        }
    }
    public synchronized void control(byte[] bytes, int length) throws IOException {
        if (length <= 0 || length > MAX_CHUNK) throw new IOException("Invalid control reply size");
        deadline.begin();
        try { out.writeByte(2); out.writeInt(length); out.write(bytes, 0, length); out.flush(); }
        finally { deadline.end(); }
    }
    public synchronized void event(int event) throws IOException {
        if (event < PHONE_ON || event > ALIVE) throw new IOException("Unknown event");
        deadline.begin();
        try { out.writeByte(EVENT); out.writeInt(1); out.writeByte(event); out.flush(); }
        finally { deadline.end(); }
    }
}
