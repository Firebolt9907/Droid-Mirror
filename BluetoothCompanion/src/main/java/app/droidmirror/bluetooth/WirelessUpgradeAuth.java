package app.droidmirror.bluetooth;

import java.io.IOException;
import java.nio.charset.StandardCharsets;
import java.security.GeneralSecurityException;
import javax.crypto.Mac;
import javax.crypto.spec.SecretKeySpec;

/** Direction-separated proofs bind a fresh challenge and the exact video cutoff. */
public final class WirelessUpgradeAuth {
    public static byte[] proof(byte[] key, String direction, byte[] nonce, byte[] offset) throws IOException {
        try {
            Mac mac = Mac.getInstance("HmacSHA256");
            mac.init(new SecretKeySpec(key, "HmacSHA256"));
            mac.update(("DroidMirror Wi-Fi " + direction + " v1").getBytes(StandardCharsets.US_ASCII));
            mac.update(nonce);
            return mac.doFinal(offset);
        } catch (GeneralSecurityException error) { throw new IOException(error); }
    }
}
