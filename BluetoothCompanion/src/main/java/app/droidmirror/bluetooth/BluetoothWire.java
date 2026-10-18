package app.droidmirror.bluetooth;

import java.io.*;
import java.nio.charset.StandardCharsets;

/** Versioned envelope: video remains scrcpy 5, control events never reach its decoder. */
public final class BluetoothWire {
    public static final byte[] MAGIC = "DMBT0006".getBytes(StandardCharsets.US_ASCII);
    public static final int VIDEO = 0, EVENT = 1, MAX_CHUNK = 16 * 1024, VIDEO_CHUNK = 1024;
    public static final int PHONE_ON = 1, SESSION_ENDED = 2, LOCAL_USE_FAILED = 3, STREAM_STARTED = 4, CAPTURE_FAILED = 5, ALIVE = 6, MINIMIZE_WINDOW = 7, PHONE_IN_USE = 8;
    // Initial/minimum Classic window; live sessions grow it from measured ACK
    // delivery. Every chunk still fits this minimum during transport changes.
    public static final int VIDEO_WINDOW_BYTES = 8 * 1024;
    private final int videoChunk;
    private DataOutputStream out;
    private final DataOutputStream classic;
    private static final class Chunk {
        final long offset; final byte[] bytes;
        Chunk(long offset, byte[] bytes) { this.offset=offset; this.bytes=bytes; }
    }
    // Retain only the bounded, unacknowledged transport window, not a second stream.
    private final java.util.ArrayDeque<Chunk> replay = new java.util.ArrayDeque<>();
    private long videoBytes, upgradeCutoff;
    private volatile boolean upgraded;
    private final WriteDeadline deadline;
    public interface SideChannel { void send(byte[] record) throws IOException; }
    private volatile SideChannel sideChannel;
    private VideoWindow videoWindow;
    private Preview preview;
    private byte[] latestBluetoothFrame;
    private boolean latencySamples;
    /** A bounded copy of live video. A slow candidate must never block Classic. */
    static final class Preview {
        static final class Record {
            final byte[] bytes; final long timestamp;
            Record(byte[] bytes, long timestamp) { this.bytes=bytes; this.timestamp=timestamp; }
        }
        private final java.util.concurrent.ArrayBlockingQueue<Record> records =
            new java.util.concurrent.ArrayBlockingQueue<>(128);
        private volatile boolean failed;
        void offer(byte[] bytes) {
            offer(new Record(bytes, 0));
        }
        void sample(long timestamp) { offer(new Record(null, timestamp)); }
        private void offer(Record record) {
            if (!failed && !records.offer(record)) { failed=true; records.clear(); }
        }
        Record poll() throws IOException {
            if (failed) throw new IOException("Wireless warm-up could not keep up with Bluetooth");
            try { return records.poll(20, java.util.concurrent.TimeUnit.MILLISECONDS); }
            catch (InterruptedException interrupted) { Thread.currentThread().interrupt(); throw new IOException(interrupted); }
        }
    }
    synchronized Preview beginPreview() throws IOException {
        if (upgraded || preview != null) throw new IOException("Video handoff already pending");
        latencySamples=true;
        return preview = new Preview();
    }
    synchronized void endPreview(Preview candidate) { if (preview == candidate) preview=null; }
    public synchronized void videoFrameSent() {
        if (preview != null) preview.offer(new byte[0]);
    }
    public synchronized void videoFrameSent(byte[] frame) {
        // A static screen may produce no fresh frames during discovery. Keep a
        // bounded, complete encoded packet for candidate delivery checks only.
        latestBluetoothFrame=!upgraded && frame.length<=128*1024 ? frame.clone() : null;
        videoFrameSent();
    }
    synchronized byte[] previewFrame() { return latestBluetoothFrame; }
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
        classic = out;
        out.write(MAGIC); out.flush();
    }
    public boolean writeStalled(long peerAge) { return peerAge > 5000 && deadline.expired(5000); }
    public void setVideoWindow(VideoWindow window) { videoWindow = window; }
    public void setSideChannel(SideChannel channel) { sideChannel = channel; }
    public void peerAddress(byte[] record) throws IOException {
        if (record.length != 32) throw new IOException("Invalid peer address record");
        sideRecord(3, record, record.length);
    }
    private void sideRecord(int type, byte[] bytes, int length) throws IOException {
        SideChannel channel = sideChannel;
        if (channel == null) throw new IOException("Authenticated BLE side channel unavailable");
        ByteArrayOutputStream buffer = new ByteArrayOutputStream(length + 5);
        DataOutputStream record = new DataOutputStream(buffer);
        record.writeByte(type); record.writeInt(length); record.write(bytes, 0, length);
        channel.send(buffer.toByteArray());
    }
    public synchronized void appearance(byte[] json) throws IOException {
        if (json == null || json.length == 0 || json.length > MAX_CHUNK) return;
        out.writeByte(4); out.writeInt(json.length); out.write(json); out.flush();
    }
    public void video(byte[] bytes) throws IOException {
        long captured=System.nanoTime();
        for (int offset = 0; offset < bytes.length;) {
            // A handoff commits before the receiver confirms the larger window;
            // fallback can also shrink it while this writer is waiting on ACKs.
            // Every reservation must fit either transport's capacity.
            int length = Math.min(upgraded ? Math.min(MAX_CHUNK, VIDEO_WINDOW_BYTES) : videoChunk, bytes.length - offset);
            if (videoWindow != null) videoWindow.reserve(length);
            synchronized (this) {
                deadline.begin();
                try {
                    pruneReplay();
                    replay.add(new Chunk(videoBytes, java.util.Arrays.copyOfRange(bytes, offset, offset + length)));
                    videoBytes += length;
                    try {
                        writeVideo(out, bytes, offset, length);
                        if (preview != null) preview.offer(java.util.Arrays.copyOfRange(bytes, offset, offset + length));
                    }
                    catch (IOException failed) {
                        if (!upgraded) throw failed;
                        // The authenticated BLE request supplies the exact received
                        // offset. Wait without holding this monitor so it can replay.
                        long until=System.nanoTime()+8_000_000_000L;
                        while (upgraded) {
                            long remaining=until-System.nanoTime();
                            if (remaining<=0) throw new IOException("BLE video fallback timed out",failed);
                            try { wait(Math.max(1,remaining/1_000_000)); }
                            catch (InterruptedException interrupted) { Thread.currentThread().interrupt(); throw new IOException(interrupted); }
                        }
                    }
                } finally { deadline.end(); }
            }
            offset += length;
        }
        try { latencySample(captured); }
        catch (IOException failed) { if (!upgraded) throw failed; }
    }
    // The trailing marker measures delivery of the whole packet, including
    // flow-control waits. Both paths use the same phone clock; no clock sync.
    synchronized void previewLatencySample(long timestamp) throws IOException {
        if (!upgraded) { classic.writeByte(5); classic.writeInt(8); classic.writeLong(timestamp); classic.flush(); }
    }
    private synchronized void latencySample(long captured) throws IOException {
        if (!latencySamples) return;
        out.writeByte(5); out.writeInt(8); out.writeLong(captured); out.flush();
        if (preview!=null) preview.sample(captured);
    }
    private void writeVideo(DataOutputStream target, byte[] bytes, int offset, int length) throws IOException {
        target.writeByte(VIDEO); target.writeInt(length); target.write(bytes,offset,length); target.flush();
    }
    private void pruneReplay() {
        long ack=videoWindow==null ? 0 : videoWindow.acknowledgedBytes();
        while (!replay.isEmpty() && replay.peek().offset+replay.peek().bytes.length<=ack) replay.remove();
    }
    /** Resume precisely after the last payload byte accepted by the Mac. */
    public synchronized boolean fallback(long received) throws IOException {
        if (!upgraded) return false;
        // Classic bytes committed before the handoff always precede replay on
        // the same ordered L2CAP channel, including failed receiver confirmation.
        received=Math.max(received,upgradeCutoff);
        long first=replay.isEmpty() ? videoBytes : replay.peek().offset;
        if (received<first || received>videoBytes) throw new IOException("Invalid Bluetooth resume offset");
        System.err.println("DroidMirror Bluetooth video replay bytes=" + (videoBytes-received));
        out=classic;
        if (videoWindow!=null) videoWindow.useBluetoothCapacity();
        for (Chunk chunk : replay) {
            int start=(int)Math.max(0,received-chunk.offset);
            for (int offset=start;offset<chunk.bytes.length;) {
                int length=Math.min(videoChunk,chunk.bytes.length-offset);
                if (videoWindow!=null) videoWindow.awaitBluetoothReplay(chunk.offset+offset+length,received);
                writeVideo(classic,chunk.bytes,offset,length); offset+=length;
            }
        }
        upgraded=false; pruneReplay(); notifyAll();
        return true;
    }
    /** Sparse transport heartbeat; never enters scrcpy's video decoder. */
    public synchronized void wirelessHeartbeat() throws IOException {
        if (!upgraded) return;
        out.writeByte(EVENT); out.writeInt(1); out.writeByte(ALIVE); out.flush();
    }
    public boolean isWireless() { return upgraded; }
    // Commit only between complete envelope records. The decoder sees the same byte stream.
    public synchronized boolean upgrade(OutputStream stream, byte[] key, byte[] nonce, byte[] profile) throws IOException {
        if (upgraded) return false;
        DataOutputStream next = new DataOutputStream(stream);
        byte[] offset = java.nio.ByteBuffer.allocate(8).putLong(videoBytes).array();
        next.write(offset);
        byte[] authenticated = java.nio.ByteBuffer.allocate(profile.length + 8).put(profile).put(offset).array();
        next.write(WirelessUpgradeAuth.proof(key, "server", nonce, authenticated));
        next.write(MAGIC); next.flush();
        upgradeCutoff=videoBytes; out = next; upgraded = true;
        return true;
    }
    public void enableWirelessThroughput() {
        if (!upgraded) throw new IllegalStateException("Wireless video is not connected");
        if (videoWindow != null) videoWindow.useWirelessCapacity();
    }
    public void control(byte[] bytes, int length) throws IOException {
        if (length <= 0 || length > MAX_CHUNK) throw new IOException("Invalid control reply size");
        sideRecord(2, bytes, length);
    }
    public void event(int event) throws IOException {
        if (event < PHONE_ON || event > PHONE_IN_USE) throw new IOException("Unknown event");
        sideRecord(EVENT, new byte[]{(byte)event}, 1);
    }
}
