import app.droidmirror.bluetooth.VideoWire;
import java.io.*;
import java.util.Arrays;

public final class VideoWireTest {
    static void require(boolean condition) { if (!condition) throw new AssertionError(); }
    public static void main(String[] args) throws Exception {
        ByteArrayOutputStream bytes = new ByteArrayOutputStream();
        VideoWire.header(new DataOutputStream(bytes), "Phone", 480, 1056);
        DataInputStream in = new DataInputStream(new ByteArrayInputStream(bytes.toByteArray()));
        require(bytes.size() == 81);
        require(in.readUnsignedByte() == 0);
        byte[] name = new byte[64]; in.readFully(name);
        require(name[0] == 'P' && name[63] == 0);
        require(in.readInt() == 0x68323635);
        require(in.readInt() == 0x80000000);
        require(in.readInt() == 480 && in.readInt() == 1056 && in.available() == 0);
        byte[] payload = {0, 0, 0, 1, 0x65, 1, 2};
        in = new DataInputStream(new ByteArrayInputStream(VideoWire.packet(payload, 123456, false, true)));
        require(in.readLong() == ((1L << 61) | 123456));
        require(in.readInt() == payload.length);
        byte[] copy = new byte[payload.length]; in.readFully(copy);
        require(Arrays.equals(payload, copy));
        in = new DataInputStream(new ByteArrayInputStream(VideoWire.packet(payload, 999, true, true)));
        require(in.readLong() == (1L << 62));
        require(Arrays.equals(VideoWire.dimensions(1080, 2400), new int[]{306, 680}));
        require(Arrays.equals(VideoWire.dimensions(1920, 1080), new int[]{544, 306}));
        require(Arrays.equals(VideoWire.dimensions(320, 640), new int[]{320, 640}));
        for (int length : new int[]{0, VideoWire.MAX_PACKET + 1}) {
            try { VideoWire.packet(new byte[length], 0, false, false); throw new AssertionError(); }
            catch (IOException expected) {}
        }
        System.out.println("VideoWire: scrcpy 5 header, flags, frame boundaries, dimensions, and packet bounds passed");
    }
}
