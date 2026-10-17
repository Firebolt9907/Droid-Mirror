package app.droidmirror.bluetooth;

import android.content.Context;
import android.content.SharedPreferences;
import android.util.Base64;
import java.io.IOException;
import java.security.SecureRandom;

/** A one-time code binds the two transports without sending secrets over Classic. */
public final class BlePairing {
    /** Never creates pairing material while processing an unauthenticated BLE hello. */
    public static synchronized byte[] notificationKey(Context context) throws java.security.GeneralSecurityException, IOException {
        String peer = context.getSharedPreferences("ready", Context.MODE_PRIVATE).getString("peer", "");
        if (peer.isEmpty()) return null;
        String saved = context.getSharedPreferences("ble_pairing", Context.MODE_PRIVATE).getString(peer, null);
        if (saved == null) return null;
        byte[] pairing;
        try { pairing = Base64.decode(saved, Base64.NO_WRAP); }
        catch (IllegalArgumentException invalid) { throw new IOException("Invalid BLE pairing code", invalid); }
        try { return PairingKeys.notifications(pairing); }
        finally { java.util.Arrays.fill(pairing, (byte)0); }
    }
    static synchronized byte[] key(Context context, String peer) throws IOException {
        SharedPreferences store = context.getSharedPreferences("ble_pairing", Context.MODE_PRIVATE);
        String saved = store.getString(peer, null);
        if (saved != null) {
            byte[] key = Base64.decode(saved, Base64.NO_WRAP);
            if (key.length != 32) throw new IOException("Invalid BLE pairing code");
            return key;
        }
        byte[] key = new byte[32]; new SecureRandom().nextBytes(key);
        if (!store.edit().putString(peer, Base64.encodeToString(key, Base64.NO_WRAP)).commit())
            throw new IOException("Could not save BLE pairing code");
        return key;
    }
}
