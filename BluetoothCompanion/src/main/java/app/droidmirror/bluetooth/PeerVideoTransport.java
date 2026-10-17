package app.droidmirror.bluetooth;

import java.io.IOException;
import java.util.Arrays;

/** Session-owned Iroh endpoint. Only the paired Mac may reach the local video handoff. */
final class PeerVideoTransport implements AutoCloseable {
    private long handle;
    private android.net.wifi.WifiManager.MulticastLock multicast;

    PeerVideoTransport(android.content.Context context, byte[] key) throws IOException {
        try {
            System.loadLibrary("droidmirror_peer");
            android.net.wifi.WifiManager wifi = (android.net.wifi.WifiManager)
                context.getApplicationContext().getSystemService(android.content.Context.WIFI_SERVICE);
            if (wifi != null) {
                multicast = wifi.createMulticastLock("DroidMirror Iroh LAN discovery");
                multicast.setReferenceCounted(false);
                multicast.acquire();
            }
            handle = nativeStart(context.getApplicationContext(), key);
            if (handle == 0) throw new IOException("Iroh endpoint did not start");
        } catch (UnsatisfiedLinkError | RuntimeException error) {
            close();
            throw new IOException("Iroh native transport unavailable; install matching builds", error);
        } catch (IOException error) {
            close(); throw error;
        } finally { Arrays.fill(key, (byte) 0); }
    }

    private static native long nativeStart(android.content.Context context, byte[] key) throws IOException;
    private static native void nativeStop(long handle);

    @Override public synchronized void close() {
        if (handle != 0) { nativeStop(handle); handle = 0; }
        if (multicast != null && multicast.isHeld()) multicast.release();
        multicast = null;
    }
}
