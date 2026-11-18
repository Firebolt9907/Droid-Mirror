package app.droidmirror.bluetooth;

import android.bluetooth.BluetoothAdapter;
import android.content.Context;
import android.content.SharedPreferences;
import java.util.ArrayList;
import java.util.Collections;
import java.util.HashSet;
import java.util.LinkedHashSet;
import java.util.List;
import java.util.Set;

/**
 * The computers (Macs or Linux laptops) trusted to mirror this phone and use its
 * background features. All trusted computers are equal: there is no primary
 * computer. Each keeps its own independent 256-bit pairing code in
 * {@code ble_pairing}, so trusting another computer never changes or reveals an
 * existing one's code. Background features are gated on each computer's own
 * authenticated Bluetooth session, never on this list alone.
 *
 * <p>Older releases trusted exactly one computer, stored as {@code ready/peer}.
 * It is migrated into {@code ready/peers} on first use.
 */
public final class ComputerPeers {
    private ComputerPeers() {}
    /** Background sessions, advertising sets and Iroh endpoints are bounded per computer. */
    public static final int MAXIMUM = 2;

    private static SharedPreferences ready(Context context) {
        return context.getSharedPreferences("ready", Context.MODE_PRIVATE);
    }

    private static void migrate(SharedPreferences ready) {
        String legacy = ready.getString("peer", "");
        if (legacy == null || legacy.isEmpty()) return;
        Set<String> peers = new HashSet<>(ready.getStringSet("peers", Collections.emptySet()));
        if (BluetoothAdapter.checkBluetoothAddress(legacy) && peers.size() < MAXIMUM) peers.add(legacy);
        ready.edit().putStringSet("peers", peers).remove("peer").commit();
    }

    /** All trusted computers in a stable (address) order. */
    public static synchronized List<String> all(Context context) {
        SharedPreferences ready = ready(context);
        migrate(ready);
        List<String> result = new ArrayList<>();
        for (String peer : ready.getStringSet("peers", Collections.emptySet()))
            if (BluetoothAdapter.checkBluetoothAddress(peer)) result.add(peer);
        Collections.sort(result);
        return result;
    }

    public static boolean contains(Context context, String address) {
        return address != null && all(context).contains(address);
    }

    /** Comma-separated, order-stable representation used by the shell L2CAP listener. */
    public static String joined(Context context) {
        return String.join(",", all(context));
    }

    /** Adds a computer; false when the address is invalid or two computers are already trusted. */
    public static synchronized boolean add(Context context, String address) {
        if (!BluetoothAdapter.checkBluetoothAddress(address)) return false;
        List<String> current = all(context);
        if (current.contains(address)) return true;
        if (current.size() >= MAXIMUM) return false;
        Set<String> peers = new HashSet<>(current);
        peers.add(address);
        return ready(context).edit().putStringSet("peers", peers).commit();
    }

    /** Removes a computer and its pairing code. */
    public static synchronized boolean remove(Context context, String address) {
        Set<String> peers = new HashSet<>(all(context));
        peers.remove(address);
        boolean saved = ready(context).edit().putStringSet("peers", peers).commit();
        context.getSharedPreferences("ble_pairing", Context.MODE_PRIVATE).edit().remove(address).commit();
        return saved;
    }

    /** Parses the listener's comma-separated list, ignoring invalid entries. */
    public static Set<String> parse(String joined) {
        LinkedHashSet<String> result = new LinkedHashSet<>();
        if (joined == null) return result;
        for (String value : joined.split(",")) {
            String address = value.trim();
            if (BluetoothAdapter.checkBluetoothAddress(address)) result.add(address);
        }
        return result;
    }
}
