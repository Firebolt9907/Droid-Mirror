package app.droidmirror.bluetooth;

import java.io.*;
import java.nio.charset.StandardCharsets;

/** Versioned envelope: video remains scrcpy 5, control events never reach its decoder. */
public final class BluetoothWire {
    public static final byte[] MAGIC = "DMBT0003".getBytes(StandardCharsets.US_ASCII);
    public static final int VIDEO = 0, EVENT = 1, MAX_CHUNK = 16 * 1024;
    public static final int PHONE_ON = 1, SESSION_ENDED = 2, LOCAL_USE_FAILED = 3, STREAM_STARTED = 4, CAPTURE_FAILED = 5;
    private final DataOutputStream out;
    public BluetoothWire(OutputStream stream) throws IOException {
        out = new DataOutputStream(stream); out.write(MAGIC);
    }
    public synchronized void video(byte[] bytes) throws IOException {
        for (int offset = 0; offset < bytes.length; offset += MAX_CHUNK) {
            int length = Math.min(MAX_CHUNK, bytes.length - offset);
            out.writeByte(VIDEO); out.writeInt(length); out.write(bytes, offset, length);
        }
        out.flush();
    }
    public synchronized void event(int event) throws IOException {
        if (event < PHONE_ON || event > CAPTURE_FAILED) throw new IOException("Unknown event");
        out.writeByte(EVENT); out.writeInt(1); out.writeByte(event); out.flush();
    }
}
