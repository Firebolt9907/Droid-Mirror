package app.droidmirror.bluetooth;

import java.nio.ByteBuffer;
import java.nio.charset.StandardCharsets;
import java.security.GeneralSecurityException;
import java.util.UUID;
import javax.crypto.Mac;
import javax.crypto.spec.SecretKeySpec;

/** Presence proofs have no authority in the mirror/notification command protocols. */
public final class PresenceProtocol {
    private PresenceProtocol() {}
    private static byte[] hmac(byte[] key, byte[] data) throws GeneralSecurityException {
        if (key.length != 32) throw new GeneralSecurityException("Invalid presence key");
        Mac mac = Mac.getInstance("HmacSHA256");
        mac.init(new SecretKeySpec(key, "HmacSHA256"));
        return mac.doFinal(data);
    }
    public static UUID uuid(byte[] key, String label) throws GeneralSecurityException {
        byte[] b = hmac(key, label.getBytes(StandardCharsets.UTF_8));
        b[6] = (byte)((b[6] & 15) | 128); b[8] = (byte)((b[8] & 63) | 128);
        ByteBuffer buffer = ByteBuffer.wrap(b);
        return new UUID(buffer.getLong(), buffer.getLong());
    }
    public static byte[] proof(byte[] key, String transport, byte[] nonce) throws GeneralSecurityException {
        if (nonce.length != 16 || !(transport.equals("gatt") || transport.equals("classic")))
            throw new GeneralSecurityException("Invalid presence challenge");
        byte[] label = ("DroidMirror presence " + transport + " v1").getBytes(StandardCharsets.UTF_8);
        return hmac(key, ByteBuffer.allocate(label.length + nonce.length).put(label).put(nonce).array());
    }
}
