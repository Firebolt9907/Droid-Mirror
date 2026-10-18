package app.droidmirror.bluetooth;

import java.nio.charset.StandardCharsets;
import java.security.GeneralSecurityException;
import javax.crypto.Mac;
import javax.crypto.spec.SecretKeySpec;

/** Separate notification credentials derived from the Mac's single pairing code. */
public final class PairingKeys {
    private PairingKeys() {}
    public static byte[] notifications(byte[] pairing) throws GeneralSecurityException {
        if (pairing.length != 32) throw new GeneralSecurityException("Invalid pairing code");
        Mac mac = Mac.getInstance("HmacSHA256");
        mac.init(new SecretKeySpec(pairing, "HmacSHA256"));
        return mac.doFinal("DroidMirror notifications pairing v1".getBytes(StandardCharsets.US_ASCII));
    }
}
