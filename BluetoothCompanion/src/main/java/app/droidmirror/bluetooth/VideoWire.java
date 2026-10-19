package app.droidmirror.bluetooth;

import java.io.*;
import java.nio.charset.StandardCharsets;

/** scrcpy 5.0 video wire format. All integers use network byte order. */
public final class VideoWire {
    public static final long CONFIG = 1L << 62;
    public static final long KEY_FRAME = 1L << 61;
    public static final int MAX_PACKET = 128 * 1024;
    private VideoWire() {}
    public static void header(DataOutputStream out, String name, int width, int height) throws IOException {
        deviceHeader(out, name);
        out.writeInt(HevcCapturePolicy.WIRE_CODEC_ID); // h265, regular HEVC
        out.writeInt(0x80000000); // v5 session packet
        out.writeInt(width);
        out.writeInt(height);
    }
    public static void deviceHeader(DataOutputStream out, String name) throws IOException {
        out.writeByte(0); // forward-connection dummy byte
        byte[] field = new byte[64];
        byte[] utf8 = name.getBytes(StandardCharsets.UTF_8);
        System.arraycopy(utf8, 0, field, 0, Math.min(utf8.length, 63));
        out.write(field);
    }
    public static byte[] packet(byte[] payload, long pts, boolean config, boolean key) throws IOException {
        if (payload.length == 0 || payload.length > MAX_PACKET) throw new IOException("Encoder packet too large");
        ByteArrayOutputStream bytes = new ByteArrayOutputStream(payload.length + 12);
        DataOutputStream out = new DataOutputStream(bytes);
        out.writeLong(config ? CONFIG : ((pts & ((1L << 61) - 1)) | (key ? KEY_FRAME : 0)));
        out.writeInt(payload.length); out.write(payload);
        return bytes.toByteArray();
    }
    public static int[] dimensions(int width, int height) {
        if (width < 16 || height < 16) throw new IllegalArgumentException("Invalid display size");
        int limit = (int) Math.min(Math.max(width, height), (long) Math.max(width, height) * HevcCapturePolicy.BLUETOOTH_SHORT_EDGE / Math.min(width, height));
        return com.genymobile.scrcpy.model.ExactAspectRatio.fit(width, height, limit, 2, null);
    }
}
