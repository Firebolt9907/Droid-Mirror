package app.droidmirror.bluetooth;

import android.content.Context;
import android.content.SharedPreferences;

/** One persisted switch; imports enabled state from either pre-0.18 service. */
public final class BackgroundBridgePreferences {
    private BackgroundBridgePreferences() {}

    public static synchronized boolean enabled(Context context) {
        SharedPreferences ready = context.getSharedPreferences("ready", Context.MODE_PRIVATE);
        if (!ready.getBoolean("bridgeMerged", false)) {
            boolean enabled = ready.getBoolean("enabled", false)
                || context.getSharedPreferences("bridge", Context.MODE_PRIVATE).getBoolean("enabled", false);
            // Persist migration before boot/service startup; an explicit stop must survive process death.
            if (!ready.edit().putBoolean("enabled", enabled).putBoolean("bridgeMerged", true).commit()) return false;
        }
        return ready.getBoolean("enabled", false);
    }

    public static synchronized void setEnabled(Context context, boolean enabled) {
        context.getSharedPreferences("ready", Context.MODE_PRIVATE).edit()
            .putBoolean("enabled", enabled).putBoolean("bridgeMerged", true).commit();
    }
}
