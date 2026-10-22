package app.droidmirror.bluetooth;

import java.io.IOException;
import java.util.Arrays;

/** Readiness-owned Iroh endpoint. Only the paired Mac may reach the local video handoff. */
final class PeerVideoTransport implements AutoCloseable {
    private final android.content.Context context;
    private long handle;
    private volatile boolean closed;
    private Thread publisher;
    private volatile BluetoothWire wire;
    private android.net.wifi.WifiManager.MulticastLock multicast;

    PeerVideoTransport(android.content.Context context, byte[] key, BluetoothWire wire) throws IOException {
        this.context = context.getApplicationContext();
        this.wire = wire;
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
            publisher = new Thread(() -> publishAddresses(), "IrohAddressPublisher");
            publisher.start();
        } catch (UnsatisfiedLinkError | RuntimeException error) {
            close();
            throw new IOException("Iroh native transport unavailable; install matching builds", error);
        } catch (IOException error) {
            close(); throw error;
        } finally { Arrays.fill(key, (byte) 0); }
    }

    private static native long nativeStart(android.content.Context context, byte[] key) throws IOException;
    private static native void nativeStop(long handle);
    private static native String nativeAddresses(long handle);

    private synchronized String addresses() { return handle == 0 ? "" : nativeAddresses(handle); }

    synchronized void attach(BluetoothWire wire) {
        this.wire = wire;
        // Publish immediately after BLE authentication instead of waiting for
        // the idle one-second interface refresh. Capture starts independently.
        notifyAll();
    }

    private void publishAddresses() {
        String previous = "";
        BluetoothWire previousWire = null;
        try {
            while (!closed) {
                BluetoothWire wire = this.wire;
                if (wire != previousWire) { previous = ""; previousWire = wire; }
                String nativeValue = addresses();
                if (wire != null && nativeValue != null && !nativeValue.isEmpty()) {
                    java.util.List<java.net.InetAddress> interfaces = new java.util.ArrayList<>();
                    try {
                        java.util.Enumeration<java.net.NetworkInterface> all = java.net.NetworkInterface.getNetworkInterfaces();
                        while (all != null && all.hasMoreElements())
                            interfaces.addAll(java.util.Collections.list(all.nextElement().getInetAddresses()));
                    } catch (java.net.SocketException | SecurityException ignored) { }
                    // Android restricts native interface enumeration. LinkProperties
                    // also supplies addresses for the active VpnService network.
                    try {
                        android.net.ConnectivityManager networks = context.getSystemService(android.net.ConnectivityManager.class);
                        if (networks != null) for (android.net.Network network : networks.getAllNetworks()) {
                            android.net.LinkProperties properties = networks.getLinkProperties(network);
                            if (properties != null) for (android.net.LinkAddress address : properties.getLinkAddresses())
                                interfaces.add(address.getAddress());
                        }
                    } catch (SecurityException ignored) { }
                    java.util.List<byte[]> records = PeerAddress.candidates(nativeValue, interfaces);
                    StringBuilder signature = new StringBuilder();
                    for (byte[] record : records) signature.append(java.util.Arrays.toString(record));
                    if (!records.isEmpty() && !signature.toString().equals(previous)) {
                        try {
                            wire.peerAddress(PeerAddress.reset());
                            for (byte[] record : records) wire.peerAddress(record);
                        } catch (IOException ended) {
                            // A session ending must not stop idle LAN discovery.
                            Thread.sleep(100); continue;
                        }
                        previous = signature.toString();
                        android.util.Log.i("DroidMirrorIroh", "Shared " + records.size() + " direct IP candidates over authenticated BLE");
                    }
                }
                synchronized (this) {
                    // If attach raced this iteration, process the new session
                    // now rather than losing its wakeup just before wait().
                    if (!closed && this.wire == wire) wait(1000);
                }
            }
        } catch (InterruptedException stopped) { Thread.currentThread().interrupt(); }
    }

    @Override public synchronized void close() {
        closed = true;
        if (publisher != null) publisher.interrupt();
        if (handle != 0) { nativeStop(handle); handle = 0; }
        if (multicast != null && multicast.isHeld()) multicast.release();
        multicast = null;
    }
}
