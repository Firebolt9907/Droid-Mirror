package app.droidmirror.bluetooth;

import android.content.Context;
import android.content.SharedPreferences;
import android.provider.Settings;

/** App-side reboot/crash recovery, independent of the availability of Shizuku after boot. */
final class HapticVibrationRecovery {
    private static HapticVibrationLease.Settings settings(Context context) {
        return new HapticVibrationLease.Settings() {
            public String read() { return Settings.System.getString(context.getContentResolver(), "vibrate_on"); }
            public void write(String value) {
                // Apps cannot delete platform-defined settings, even with
                // WRITE_SECURE_SETTINGS. Null restores the default immediately;
                // the shell watchdog also removes the empty row.
                if (!Settings.System.putString(context.getContentResolver(), "vibrate_on", value))
                    throw new IllegalStateException("Could not restore vibration");
            }
        };
    }
    private static HapticVibrationLease.Journal journal(Context context) {
        SharedPreferences prefs = context.createDeviceProtectedStorageContext().getSharedPreferences("haptic-recovery", Context.MODE_PRIVATE);
        return new HapticVibrationLease.Journal() {
            public String read() { return prefs.getString("original", null); }
            public void write(String value) {
                SharedPreferences.Editor edit = prefs.edit();
                if (value == null) edit.remove("original"); else edit.putString("original", value);
                if (!edit.commit()) throw new IllegalStateException("Could not save vibration recovery");
            }
        };
    }
    static synchronized String prepare(Context context) throws Exception {
        if (context.checkSelfPermission("android.permission.WRITE_SECURE_SETTINGS") != android.content.pm.PackageManager.PERMISSION_GRANTED)
            throw new SecurityException("Vibration recovery permission unavailable");
        return HapticVibrationLease.snapshot(settings(context), journal(context));
    }
    static synchronized void restore(Context context) {
        try { HapticVibrationLease.restore(settings(context), journal(context)); }
        catch (Exception failure) { android.util.Log.e("DroidMirrorHaptics", "Vibration recovery pending", failure); }
    }
    static synchronized void restoreSetting(Context context) {
        // Early recovery may race an in-flight shell startup. Retain its durable
        // snapshot until the serialized final close confirms startup has ended.
        try { HapticVibrationLease.restoreSetting(settings(context), journal(context)); }
        catch (Exception failure) { android.util.Log.e("DroidMirrorHaptics", "Early vibration recovery pending", failure); }
    }
    private HapticVibrationRecovery() {}
}
