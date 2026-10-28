package app.droidmirror.bluetooth;

import java.nio.charset.StandardCharsets;
import java.security.GeneralSecurityException;
import java.security.SecureRandom;
import javax.crypto.Cipher;
import javax.crypto.spec.GCMParameterSpec;
import javax.crypto.spec.SecretKeySpec;

/** Wire format shared with QRPairingProtocol.swift. No saved key is mutated here. */
public final class QRKeyTransfer {
    public static final String CHARACTERISTIC = "A946DDA2-7E71-4ACD-B670-F77C3D715891";
    public static byte[] seal(byte[] key, byte[] secret, String service, String mac) throws GeneralSecurityException {
        byte[] nonce = new byte[12]; new SecureRandom().nextBytes(nonce);
        return seal(key, secret, service, mac, nonce);
    }
    static byte[] seal(byte[] key, byte[] secret, String service, String mac, byte[] nonce) throws GeneralSecurityException {
        if (key.length != 32 || secret.length != 32 || nonce.length != 12)
            throw new GeneralSecurityException("Invalid key transfer size");
        Cipher cipher = Cipher.getInstance("AES/GCM/NoPadding");
        cipher.init(Cipher.ENCRYPT_MODE, new SecretKeySpec(secret, "AES"), new GCMParameterSpec(128, nonce));
        cipher.updateAAD(("DroidMirror QR key transfer v1|" + service.toUpperCase(java.util.Locale.ROOT)
            + "|" + mac.toUpperCase(java.util.Locale.ROOT)).getBytes(StandardCharsets.UTF_8));
        byte[] sealed = cipher.doFinal(key);
        byte[] packet = new byte[nonce.length + sealed.length];
        System.arraycopy(nonce, 0, packet, 0, nonce.length);
        System.arraycopy(sealed, 0, packet, nonce.length, sealed.length);
        return packet;
    }
    public static byte[] acknowledgement(byte[] packet, byte[] secret, String service, String mac) throws GeneralSecurityException {
        javax.crypto.Mac hmac = javax.crypto.Mac.getInstance("HmacSHA256");
        hmac.init(new SecretKeySpec(secret, "HmacSHA256"));
        hmac.update(("DroidMirror QR key transfer v1|" + service.toUpperCase(java.util.Locale.ROOT)
            + "|" + mac.toUpperCase(java.util.Locale.ROOT) + "|saved|").getBytes(StandardCharsets.UTF_8));
        return java.util.Arrays.copyOf(hmac.doFinal(packet), 16);
    }
    private QRKeyTransfer() {}
}
