package app.droidmirror.bluetooth;

import java.nio.charset.StandardCharsets;
import java.security.GeneralSecurityException;
import javax.crypto.Mac;
import javax.crypto.spec.SecretKeySpec;

/** Separate notification credentials derived from the Mac's single pairing code. */
public final class PairingKeys {
    private PairingKeys() {}
    /** Discovery hint only; never a replacement for the authenticated handshake. */
    public static java.util.UUID discovery(byte[] notificationKey) throws GeneralSecurityException {
        if (notificationKey.length != 32) throw new GeneralSecurityException("Invalid notification key");
        Mac mac = Mac.getInstance("HmacSHA256");
        mac.init(new SecretKeySpec(notificationKey, "HmacSHA256"));
        byte[] bytes = mac.doFinal("DroidMirror BLE discovery v1".getBytes(StandardCharsets.US_ASCII));
        bytes[6] = (byte)((bytes[6] & 0x0f) | 0x80);
        bytes[8] = (byte)((bytes[8] & 0x3f) | 0x80);
        java.nio.ByteBuffer buffer = java.nio.ByteBuffer.wrap(bytes);
        return new java.util.UUID(buffer.getLong(), buffer.getLong());
    }
    public static byte[] notifications(byte[] pairing) throws GeneralSecurityException {
        if (pairing.length != 32) throw new GeneralSecurityException("Invalid pairing code");
        Mac mac = Mac.getInstance("HmacSHA256");
        mac.init(new SecretKeySpec(pairing, "HmacSHA256"));
        return mac.doFinal("DroidMirror notifications pairing v1".getBytes(StandardCharsets.US_ASCII));
    }
}
