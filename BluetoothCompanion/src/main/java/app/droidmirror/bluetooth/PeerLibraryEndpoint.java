package app.droidmirror.bluetooth;

import android.content.Context;
import java.util.*;
import java.net.*;
import org.json.JSONArray;

/** Separately derived Iroh identity/ALPN; never borrows the video endpoint. */
public final class PeerLibraryEndpoint implements AutoCloseable {
    private long handle;
    public PeerLibraryEndpoint(Context context, byte[] key) throws java.io.IOException {
        try {
            System.loadLibrary("droidmirror_peer");
            handle = nativeStart(context.getApplicationContext(), key);
            if (handle == 0) throw new java.io.IOException("Library endpoint unavailable");
        } finally { Arrays.fill(key, (byte) 0); }
    }
    private static native long nativeStart(Context context, byte[] key);
    public synchronized JSONArray addresses(Context context) {
        JSONArray result = new JSONArray();
        if (handle == 0) return result;
        String nativeValue = PeerVideoTransport.nativeAddresses(handle);
        List<InetAddress> interfaces = new ArrayList<>();
        try {
            Enumeration<NetworkInterface> all = NetworkInterface.getNetworkInterfaces();
            while (all != null && all.hasMoreElements()) interfaces.addAll(Collections.list(all.nextElement().getInetAddresses()));
            android.net.ConnectivityManager networks = context.getSystemService(android.net.ConnectivityManager.class);
            for (android.net.Network network : networks.getAllNetworks()) {
                android.net.LinkProperties properties = networks.getLinkProperties(network);
                if (properties != null) for (android.net.LinkAddress address : properties.getLinkAddresses()) interfaces.add(address.getAddress());
            }
        } catch (Exception ignored) {}
        if (nativeValue != null) for (byte[] record : PeerAddress.candidates(nativeValue, interfaces))
            result.put(android.util.Base64.encodeToString(record, android.util.Base64.NO_WRAP));
        return result;
    }
    public synchronized void close() { if (handle != 0) { PeerVideoTransport.nativeStop(handle); handle = 0; } }
}
