import android.content.Context;
import android.content.SharedPreferences;
import app.droidmirror.bluetooth.ComputerPeers;
import java.util.*;

/** Multi-computer trust: migration from one Mac, ordering, removal and promotion. */
public final class ComputerPeersTest {
    static final class Store implements SharedPreferences {
        final Map<String, Object> values = new HashMap<>();
        public boolean getBoolean(String k, boolean f) { Object v = values.get(k); return v == null ? f : (Boolean) v; }
        public String getString(String k, String f) { Object v = values.get(k); return v == null ? f : (String) v; }
        @SuppressWarnings("unchecked")
        public Set<String> getStringSet(String k, Set<String> f) { Object v = values.get(k); return v == null ? f : new HashSet<>((Set<String>) v); }
        public Editor edit() {
            Map<String, Object> pending = new HashMap<>(); Set<String> removed = new HashSet<>();
            return new Editor() {
                public Editor putBoolean(String k, boolean v) { pending.put(k, v); return this; }
                public Editor putString(String k, String v) { pending.put(k, v); return this; }
                public Editor putStringSet(String k, Set<String> v) { pending.put(k, new HashSet<>(v)); return this; }
                public Editor remove(String k) { removed.add(k); return this; }
                public boolean commit() { removed.forEach(values::remove); values.putAll(pending); return true; }
            };
        }
    }
    static final class Fake extends Context {
        final Map<String, Store> stores = new HashMap<>();
        public SharedPreferences getSharedPreferences(String name, int mode) { return stores.computeIfAbsent(name, n -> new Store()); }
    }
    static void check(boolean condition, String message) { if (!condition) throw new AssertionError(message); }

    public static void main(String[] args) {
        String mac = "84:2F:57:39:9B:EE", linux = "18:26:49:7E:03:A0", other = "00:11:22:33:44:55";
        Fake context = new Fake();
        // An existing single-Mac install migrates into the equal-peers list.
        context.getSharedPreferences("ready", 0).edit().putString("peer", mac).commit();
        context.getSharedPreferences("ble_pairing", 0).edit().putString(mac, "mac-code").commit();
        check(ComputerPeers.all(context).equals(List.of(mac)), "legacy Mac migrates");
        check(!context.getSharedPreferences("ready", 0).contains("peer"), "no primary computer remains");
        check(ComputerPeers.add(context, linux), "add Linux laptop");
        check(ComputerPeers.all(context).equals(List.of(linux, mac)), "address order: " + ComputerPeers.all(context));
        check(!ComputerPeers.add(context, other), "at most two computers");
        check(ComputerPeers.joined(context).equals(linux + "," + mac), "listener list");
        check(ComputerPeers.parse(" " + mac + ",bogus," + linux).equals(new LinkedHashSet<>(List.of(mac, linux))), "parse ignores invalid entries");
        check(!ComputerPeers.add(context, "not-an-address"), "invalid address rejected");
        context.getSharedPreferences("ble_pairing", 0).edit().putString(linux, "linux-code").commit();
        check(ComputerPeers.remove(context, mac), "remove Mac");
        check(ComputerPeers.all(context).equals(List.of(linux)), "remaining computer");
        check(!context.getSharedPreferences("ble_pairing", 0).contains(mac), "removed computer's code deleted");
        check(context.getSharedPreferences("ble_pairing", 0).contains(linux), "other computer's code kept");
        check(ComputerPeers.add(context, other), "room for a second computer again");
        check(ComputerPeers.remove(context, other) && ComputerPeers.remove(context, linux), "remove all");
        check(ComputerPeers.all(context).isEmpty(), "no computers left");
        System.out.println("ComputerPeersTest passed");
    }
}
