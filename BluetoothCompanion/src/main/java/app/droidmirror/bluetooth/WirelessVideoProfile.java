package app.droidmirror.bluetooth;

import java.io.IOException;
import java.nio.ByteBuffer;

/** The hybrid HEVC Wi-Fi target, authenticated as part of the upgrade request. */
public final class WirelessVideoProfile {
    public static final int WIRE_SIZE = 12;
    public final int maxSize, fps, bitRate;

    public WirelessVideoProfile(int maxSize, int fps, int bitRate) throws IOException {
        if ((maxSize != 0 && (maxSize < 128 || maxSize > 8192)) || fps < 1 || fps > 240
                || bitRate < 256000 || bitRate > 64000000) throw new IOException("Invalid Wi-Fi video profile");
        this.maxSize = maxSize; this.fps = fps; this.bitRate = bitRate;
    }

    public byte[] bytes() { return ByteBuffer.allocate(WIRE_SIZE).putInt(maxSize).putInt(fps).putInt(bitRate).array(); }

    public static WirelessVideoProfile parse(byte[] bytes) throws IOException {
        if (bytes.length != WIRE_SIZE) throw new IOException("Invalid Wi-Fi profile length");
        ByteBuffer buffer = ByteBuffer.wrap(bytes);
        return new WirelessVideoProfile(buffer.getInt(), buffer.getInt(), buffer.getInt());
    }
}
