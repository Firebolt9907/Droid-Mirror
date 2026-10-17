package app.droidmirror.bluetooth;

import java.util.concurrent.ConcurrentHashMap;

/** ATT MTU belongs to the shared connection, not a per-session GATT server. */
public final class BleLinkMtu {
    private static final ConcurrentHashMap<String, Integer> values = new ConcurrentHashMap<>();
    private BleLinkMtu() {}
    public static int get(String address) { return values.getOrDefault(address, 23); }
    public static void negotiated(String address, int mtu) {
        if (mtu >= 23 && mtu <= 517) values.put(address, mtu);
    }
    // A non-prepared ATT write proves at least this capacity, even if this
    // process joined an existing link and missed the MTU negotiation callback.
    public static void observedWrite(String address, int bytes) {
        if (bytes > 0 && bytes <= 514) values.merge(address, bytes + 3, Math::max);
    }
    public static void disconnected(String address) { values.remove(address); }
}
