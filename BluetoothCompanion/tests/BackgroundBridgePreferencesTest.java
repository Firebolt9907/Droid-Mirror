import android.content.Context;
import android.content.SharedPreferences;
import app.droidmirror.bluetooth.BackgroundBridgePreferences;
import java.util.HashMap;
import java.util.Map;

public final class BackgroundBridgePreferencesTest {
    static final class Store implements SharedPreferences {
        final Map<String, Object> saved = new HashMap<>();
        boolean writable = true;
        public boolean getBoolean(String key, boolean fallback) { return (Boolean)saved.getOrDefault(key, fallback); }
        public String getString(String key, String fallback) { return (String)saved.getOrDefault(key, fallback); }
        public Editor edit() {
            return new Editor() {
                final Map<String, Object> pending = new HashMap<>();
                public Editor putBoolean(String key, boolean value) { pending.put(key, value); return this; }
                public Editor putString(String key, String value) { pending.put(key, value); return this; }
                public boolean commit() {
                    if (!writable) return false;
                    saved.putAll(pending); return true;
                }
            };
        }
    }
    static final class Phone extends Context {
        final Map<String, Store> disk;
        Phone() { this(new HashMap<>()); }
        Phone(Map<String, Store> disk) { this.disk = disk; }
        public Store getSharedPreferences(String name, int mode) { return disk.computeIfAbsent(name, k -> new Store()); }
        void legacy(boolean capture, boolean discovery) {
            getSharedPreferences("ready", 0).saved.put("enabled", capture);
            getSharedPreferences("bridge", 0).saved.put("enabled", discovery);
        }
        Phone reboot() { return new Phone(disk); }
    }
    private static void check(boolean value, String message) { if (!value) throw new AssertionError(message); }
    public static void main(String[] args) {
        check(!BackgroundBridgePreferences.enabled(new Phone()), "Fresh install must stay off");
        for (boolean capture : new boolean[]{false, true}) for (boolean discovery : new boolean[]{false, true}) {
            Phone phone = new Phone(); phone.legacy(capture, discovery);
            boolean wanted = capture || discovery;
            check(BackgroundBridgePreferences.enabled(phone) == wanted, "Migrate either enabled service");
            check(BackgroundBridgePreferences.enabled(phone.reboot()) == wanted, "Migration survives reboot");
            BackgroundBridgePreferences.setEnabled(phone, false);
            check(!BackgroundBridgePreferences.enabled(phone.reboot()), "Stop survives reboot despite legacy flags");
            BackgroundBridgePreferences.setEnabled(phone.reboot(), true);
            check(BackgroundBridgePreferences.enabled(phone.reboot()), "Re-enable survives reboot");
        }
        Phone stoppedBeforeMigration = new Phone(); stoppedBeforeMigration.legacy(true, true);
        BackgroundBridgePreferences.setEnabled(stoppedBeforeMigration, false);
        check(!BackgroundBridgePreferences.enabled(stoppedBeforeMigration.reboot()), "Stop before first migration stays stopped");
        Phone failed = new Phone(); failed.legacy(false, true);
        failed.getSharedPreferences("ready", 0).writable = false;
        check(!BackgroundBridgePreferences.enabled(failed), "Do not start if migration could not persist");
        System.out.println("PASS: legacy service migration, fresh install, reboot, unified stop/re-enable, failed persistence");
    }
}
