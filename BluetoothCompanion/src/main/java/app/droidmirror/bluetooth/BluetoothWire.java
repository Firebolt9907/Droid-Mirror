package app.droidmirror.bluetooth;

import java.io.*;
import java.nio.charset.StandardCharsets;

/** Versioned envelope: video remains scrcpy 5, control events never reach its decoder. */
public final class BluetoothWire {
    public static final byte[] MAGIC = "DMBT0006".getBytes(StandardCharsets.US_ASCII);
    public static final int VIDEO = 0, EVENT = 1, MAX_CHUNK = 16 * 1024, VIDEO_CHUNK = 1024;
    public static final int PHONE_ON = 1, SESSION_ENDED = 2, LOCAL_USE_FAILED = 3, STREAM_STARTED = 4, CAPTURE_FAILED = 5, ALIVE = 6;
    // Leave room for measured BLE ACK delays and keyframe bursts on the shared radio.
    public static final int VIDEO_WINDOW_BYTES = 24 * 1024;
    private final int videoChunk;
    private final DataOutputStream out;
    private final WriteDeadline deadline;
    public interface SideChannel { void send(byte[] record) throws IOException; }
    private volatile SideChannel sideChannel;
    private VideoWindow videoWindow;
    public BluetoothWire(OutputStream stream) throws IOException {
        this(stream, () -> System.nanoTime() / 1_000_000);
    }
    public BluetoothWire(OutputStream stream, java.util.function.LongSupplier clock) throws IOException {
        this(stream, clock, VIDEO_CHUNK);
    }
    public static int videoChunkForMtu(int mtu) {
        if (mtu <= 5) return VIDEO_CHUNK;
        int packets = Math.min(4, Math.min(VIDEO_WINDOW_BYTES, MAX_CHUNK) / mtu);
        return packets == 0 ? Math.min(VIDEO_WINDOW_BYTES, MAX_CHUNK) - 5 : packets * mtu - 5;
    }
    public BluetoothWire(OutputStream stream, java.util.function.LongSupplier clock, int chunk) throws IOException {
        if (chunk <= 0 || chunk > VIDEO_WINDOW_BYTES || chunk > MAX_CHUNK) throw new IOException("Invalid video chunk size");
        videoChunk = chunk;
        deadline = new WriteDeadline(clock);
        // Coalesce the envelope
        // header and payload rather than sending five tiny header packets.
        out = new DataOutputStream(new BufferedOutputStream(stream, MAX_CHUNK + 5));
        out.write(MAGIC); out.flush();
    }
    public boolean writeStalled(long peerAge) { return peerAge > 5000 && deadline.expired(5000); }
    public void setVideoWindow(VideoWindow window) { videoWindow = window; }
    public void setSideChannel(SideChannel channel) { sideChannel = channel; }
    private void sideRecord(int type, byte[] bytes, int length) throws IOException {
        SideChannel channel = sideChannel;
        if (channel == null) throw new IOException("Authenticated BLE side channel unavailable");
        ByteArrayOutputStream buffer = new ByteArrayOutputStream(length + 5);
        DataOutputStream record = new DataOutputStream(buffer);
        record.writeByte(type); record.writeInt(length); record.write(bytes, 0, length);
        channel.send(buffer.toByteArray());
    }
    public void video(byte[] bytes) throws IOException {
        for (int offset = 0; offset < bytes.length; offset += videoChunk) {
            int length = Math.min(videoChunk, bytes.length - offset);
            if (videoWindow != null) videoWindow.reserve(length);
            synchronized (this) {
                deadline.begin();
                try { out.writeByte(VIDEO); out.writeInt(length); out.write(bytes, offset, length); out.flush(); }
                finally { deadline.end(); }
            }
        }
    }
    public void control(byte[] bytes, int length) throws IOException {
        if (length <= 0 || length > MAX_CHUNK) throw new IOException("Invalid control reply size");
        sideRecord(2, bytes, length);
    }
    public void event(int event) throws IOException {
        if (event < PHONE_ON || event > ALIVE) throw new IOException("Unknown event");
        sideRecord(EVENT, new byte[]{(byte)event}, 1);
    }
}
