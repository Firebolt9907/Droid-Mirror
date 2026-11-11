package app.droidmirror.bluetooth;

import java.nio.ByteBuffer;
import java.nio.charset.StandardCharsets;

/** DMCV0001 access units; the enclosing QUIC lane proves the BLE capability/session. */
public final class CameraVideoPacket {
    public static final int HEADER_BYTES = 36;
    public static final int MAX_PAYLOAD = 2 * 1024 * 1024;
    public static byte[] encode(int epoch, long sequence, long ptsUs, boolean keyframe, byte[] payload) {
        if (epoch <= 0 || sequence <= 0 || ptsUs < 0 || payload.length == 0 || payload.length > MAX_PAYLOAD)
            throw new IllegalArgumentException("Invalid camera packet");
        return ByteBuffer.allocate(HEADER_BYTES + payload.length)
            .put("DMCV0001".getBytes(StandardCharsets.US_ASCII)).putInt(epoch).putLong(sequence)
            .putLong(ptsUs).putInt(keyframe ? 1 : 0).putInt(payload.length).put(payload).array();
    }
    private CameraVideoPacket() {}
}
