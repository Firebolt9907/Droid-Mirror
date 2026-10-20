package app.droidmirror.bluetooth;

import com.genymobile.scrcpy.control.PinUnlock;

import android.content.Context;
import android.content.SharedPreferences;
import android.security.keystore.KeyGenParameterSpec;
import android.security.keystore.KeyProperties;
import android.util.Base64;
import java.security.KeyStore;
import java.util.Arrays;
import javax.crypto.Cipher;
import javax.crypto.KeyGenerator;
import javax.crypto.SecretKey;
import javax.crypto.spec.GCMParameterSpec;

/** App-private ciphertext; the non-exportable encryption key stays in Android Keystore. */
final class SavedUnlockPin {
    private static final String ALIAS = "droidmirror.unlock-pin.v1";
    private static SharedPreferences prefs(Context context) {
        return context.getSharedPreferences("unlock_pin", Context.MODE_PRIVATE);
    }
    static boolean configured(Context context) { return prefs(context).contains("ciphertext"); }
    static boolean paused(Context context) { return cooldownRemaining(context) > 0; }
    static long cooldownRemaining(Context context) {
        SharedPreferences preferences = prefs(context);
        if (!preferences.getBoolean("paused", false)) return 0;
        try {
            return UnlockPinCooldown.remaining(Long.parseLong(preferences.getString("attempt_at", "0")), System.currentTimeMillis());
        } catch (NumberFormatException invalid) { return 0; }
    }
    private static SecretKey key(boolean create) throws Exception {
        KeyStore store = KeyStore.getInstance("AndroidKeyStore"); store.load(null);
        SecretKey key = (SecretKey) store.getKey(ALIAS, null);
        if (key != null) return key;
        if (!create) throw new IllegalStateException("Saved PIN key unavailable. Save your PIN again.");
        KeyGenerator generator = KeyGenerator.getInstance(KeyProperties.KEY_ALGORITHM_AES, "AndroidKeyStore");
        // Background unlock intentionally requires decryption while locked. Requiring
        // user authentication here would defeat that opt-in behavior.
        generator.init(new KeyGenParameterSpec.Builder(ALIAS, KeyProperties.PURPOSE_ENCRYPT | KeyProperties.PURPOSE_DECRYPT)
            .setKeySize(256).setBlockModes(KeyProperties.BLOCK_MODE_GCM)
            .setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE).build());
        return generator.generateKey();
    }
    static synchronized void save(Context context, byte[] pin) throws Exception {
        if (!PinUnlock.valid(pin)) throw new IllegalArgumentException("Use a PIN of 4–16 digits.");
        Cipher cipher = Cipher.getInstance("AES/GCM/NoPadding");
        cipher.init(Cipher.ENCRYPT_MODE, key(true));
        byte[] encrypted = cipher.doFinal(pin);
        if (!prefs(context).edit().putString("ciphertext", Base64.encodeToString(encrypted, Base64.NO_WRAP))
            .putString("iv", Base64.encodeToString(cipher.getIV(), Base64.NO_WRAP)).putBoolean("paused", false).commit())
            throw new IllegalStateException("Could not save PIN.");
    }
    static synchronized byte[] beginAttempt(Context context) throws Exception {
        SharedPreferences preferences = prefs(context);
        if (!configured(context)) return null;
        if (paused(context)) return null; // Pause credentials, never the mirror connection.
        Cipher cipher = Cipher.getInstance("AES/GCM/NoPadding");
        cipher.init(Cipher.DECRYPT_MODE, key(false), new GCMParameterSpec(128,
            Base64.decode(preferences.getString("iv", ""), Base64.NO_WRAP)));
        byte[] pin = cipher.doFinal(Base64.decode(preferences.getString("ciphertext", ""), Base64.NO_WRAP));
        if (!PinUnlock.valid(pin) || !preferences.edit().putBoolean("paused", true).putString("attempt_at", Long.toString(System.currentTimeMillis())).commit()) {
            Arrays.fill(pin, (byte) 0); throw new IllegalStateException("Saved PIN unavailable. Save it again.");
        }
        // Persist before handing it to the daemon: a crash must not allow rapid
        // reconnect attempts. After 15 seconds only a new connection can retry.
        return pin;
    }
    static synchronized void completed(Context context) throws Exception {
        if (!prefs(context).edit().putBoolean("paused", false).commit())
            throw new IllegalStateException("Could not update automatic unlock state.");
    }
    static synchronized void remove(Context context) throws Exception {
        if (!prefs(context).edit().clear().commit()) throw new IllegalStateException("Could not remove PIN.");
        KeyStore store = KeyStore.getInstance("AndroidKeyStore"); store.load(null); store.deleteEntry(ALIAS);
    }
}
