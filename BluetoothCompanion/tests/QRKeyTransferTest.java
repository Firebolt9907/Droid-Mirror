package app.droidmirror.bluetooth;

import java.nio.file.*;
import java.util.*;

public final class QRKeyTransferTest {
    public static void main(String[] args) throws Exception {
        byte[] key = new byte[32], secret = new byte[32], nonce = new byte[12];
        for (int i = 0; i < 32; i++) { key[i] = (byte)i; secret[i] = (byte)(i + 64); }
        Arrays.fill(nonce, (byte)7);
        byte[] original = key.clone();
        String service = "7D6167CB-4DC7-4784-AB5F-045C69AFA628", mac = "AA:BB:CC:DD:EE:FF";
        byte[] packet = QRKeyTransfer.seal(key, secret, service, mac, nonce);
        if (packet.length != 60 || !Arrays.equals(key, original)) throw new AssertionError("Key must be preserved");
        byte[] ack = QRKeyTransfer.acknowledgement(packet, secret, service, mac);
        if (ack.length != 16) throw new AssertionError("Confirmation size");
        byte[] altered = packet.clone(); altered[15] ^= 1;
        if (Arrays.equals(ack, QRKeyTransfer.acknowledgement(altered, secret, service, mac))) throw new AssertionError("Confirmation must bind ciphertext");
        if (Arrays.equals(ack, QRKeyTransfer.acknowledgement(packet, secret, service, "00:00:00:00:00:00"))) throw new AssertionError("Confirmation must bind target");
        if (Arrays.equals(packet, QRKeyTransfer.seal(key, secret, service, mac))) throw new AssertionError("Random transfer nonce");
        try { QRKeyTransfer.seal(new byte[31], secret, service, mac); throw new AssertionError("Invalid key accepted"); }
        catch (java.security.GeneralSecurityException expected) {}
        String vector = Base64.getEncoder().encodeToString(packet) + "\n" + Base64.getEncoder().encodeToString(ack);
        Files.writeString(Path.of(args[0]), vector);
        System.out.println("PASS: Java key preservation, nonce freshness, authenticated confirmation and size checks");
    }
}
