package app.droidmirror.bluetooth;

import java.nio.ByteBuffer;
import java.nio.charset.StandardCharsets;
import java.security.*;
import java.util.Arrays;
import javax.crypto.*;
import javax.crypto.spec.*;

/** Per-Classic-session encrypt-then-MAC input records. Never log or persist keys. */
final class BleInputCrypto {
    private final byte[] encryption, authentication;
    private long next = 1;
    BleInputCrypto(byte[] sessionKey) throws GeneralSecurityException {
        if (sessionKey.length != 32) throw new GeneralSecurityException("Invalid BLE session key");
        encryption = hmac(sessionKey, "DroidMirror BLE encryption v1".getBytes(StandardCharsets.US_ASCII));
        authentication = hmac(sessionKey, "DroidMirror BLE authentication v1".getBytes(StandardCharsets.US_ASCII));
    }
    static byte[] hmac(byte[] key, byte[] data) throws GeneralSecurityException {
        Mac mac = Mac.getInstance("HmacSHA256"); mac.init(new SecretKeySpec(key, "HmacSHA256")); return mac.doFinal(data);
    }
    byte[] proof(byte[] challenge) throws GeneralSecurityException {
        if (challenge.length != 16) throw new GeneralSecurityException("Invalid BLE challenge");
        byte[] label="DroidMirror BLE proof v1".getBytes(StandardCharsets.US_ASCII);
        return hmac(authentication, ByteBuffer.allocate(label.length+16).put(label).put(challenge).array());
    }
    synchronized byte[] open(byte[] packet) throws GeneralSecurityException {
        if (packet.length <= 24 || packet.length > 512) throw new GeneralSecurityException("Invalid BLE input record size");
        byte[] body = Arrays.copyOf(packet, packet.length - 16);
        byte[] expected = Arrays.copyOf(hmac(authentication, body), 16);
        if (!MessageDigest.isEqual(expected, Arrays.copyOfRange(packet, body.length, packet.length)))
            throw new GeneralSecurityException("Invalid BLE input authentication");
        long sequence = ByteBuffer.wrap(body).getLong();
        if (sequence != next || sequence <= 0 || sequence == Long.MAX_VALUE)
            throw new GeneralSecurityException("BLE input sequence mismatch");
        ByteBuffer iv = ByteBuffer.allocate(16); iv.put("DMINPUT1".getBytes(StandardCharsets.US_ASCII)); iv.putLong(sequence);
        Cipher cipher = Cipher.getInstance("AES/CTR/NoPadding");
        cipher.init(Cipher.DECRYPT_MODE, new SecretKeySpec(encryption, "AES"), new IvParameterSpec(iv.array()));
        byte[] plain = cipher.doFinal(body, 8, body.length - 8); ++next; return plain;
    }
}
