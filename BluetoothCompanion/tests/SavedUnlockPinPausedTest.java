package app.droidmirror.bluetooth;
import android.content.Context;
import android.content.SharedPreferences;

public final class SavedUnlockPinPausedTest {
    public static void main(String[] args) throws Exception {
        SharedPreferences preferences = new SharedPreferences() {
            public boolean getBoolean(String key, boolean fallback) { return key.equals("paused") || fallback; }
            public String getString(String key, String fallback) { return key.equals("ciphertext") ? "encrypted" : key.equals("attempt_at") ? Long.toString(System.currentTimeMillis()) : fallback; }
            public Editor edit() { throw new AssertionError("Paused fallback must not change credential state"); }
        };
        Context context = new Context() {
            public SharedPreferences getSharedPreferences(String name, int mode) { return preferences; }
        };
        if (!SavedUnlockPin.configured(context) || !SavedUnlockPin.paused(context)) throw new AssertionError();
        if (SavedUnlockPin.beginAttempt(context) != null) throw new AssertionError("Paused PIN must be skipped");
        if (!SavedUnlockPin.paused(context)) throw new AssertionError("Manual streaming must not rearm credentials");
        System.out.println("Paused PIN: streaming proceeds without decrypting, entering, or rearming the PIN");
    }
}
