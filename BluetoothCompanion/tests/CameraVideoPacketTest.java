import app.droidmirror.bluetooth.CameraVideoPacket;
import app.droidmirror.bluetooth.CameraVideoProfile;
import java.nio.file.Files;
import java.nio.file.Path;

public final class CameraVideoPacketTest {
    static void require(boolean condition) { if (!condition) throw new AssertionError(); }
    static void rejected(Runnable body) {
        try { body.run(); } catch (IllegalArgumentException expected) { return; }
        throw new AssertionError("Accepted invalid packet");
    }
    public static void main(String[] args) throws Exception {
        var wifi = CameraVideoProfile.forTransport(true);
        require(wifi.width == 1280 && wifi.height == 720 && wifi.fps == 30 && wifi.bitRate == 3000000 && wifi.keyframeSeconds == 1);
        var ble = CameraVideoProfile.forTransport(false);
        require(ble.width == 320 && ble.height == 240 && ble.fps == 15 && ble.bitRate == 128000 && ble.keyframeSeconds == 0);
        byte[] raw = new byte[] {0, 0, 0, 1, 0x65, (byte)0xff};
        byte[] packet = CameraVideoPacket.encode(7, 1, 123456, true, raw);
        require(packet.length == 36 + raw.length);
        String header = java.util.HexFormat.of().formatHex(packet, 0, 36);
        require(header.equals("444d435630303031000000070000000000000001000000000001e2400000000100000006"));
        Files.write(Path.of(args[0]), packet); // Consumed by the actual Swift receiver codec.
        rejected(() -> CameraVideoPacket.encode(0, 1, 0, true, raw));
        rejected(() -> CameraVideoPacket.encode(1, 0, 0, true, raw));
        rejected(() -> CameraVideoPacket.encode(1, 1, -1, true, raw));
        rejected(() -> CameraVideoPacket.encode(1, 1, 0, false, new byte[0]));
        rejected(() -> CameraVideoPacket.encode(1, 1, 0, true, new byte[CameraVideoPacket.MAX_PAYLOAD + 1]));
        System.out.println("Camera binary packet/profile tests passed");
    }
}
