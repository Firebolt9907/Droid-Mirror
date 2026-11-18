package app.droidmirror.bluetooth;

import android.content.Context;
import android.content.pm.PackageManager;
import android.net.ConnectivityManager;
import android.net.LocalSocket;
import android.net.LocalSocketAddress;
import android.net.Network;
import android.net.NetworkCapabilities;
import android.net.NetworkRequest;
import android.net.wifi.aware.AttachCallback;
import android.net.wifi.aware.DiscoverySessionCallback;
import android.net.wifi.aware.PeerHandle;
import android.net.wifi.aware.PublishConfig;
import android.net.wifi.aware.PublishDiscoverySession;
import android.net.wifi.aware.WifiAwareManager;
import android.net.wifi.aware.WifiAwareNetworkSpecifier;
import android.net.wifi.aware.WifiAwareSession;
import android.os.Build;
import android.os.Handler;
import android.os.Looper;
import android.util.Log;
import java.io.IOException;
import java.io.InputStream;
import java.io.OutputStream;
import java.net.Inet6Address;
import java.net.ServerSocket;
import java.net.Socket;
import java.nio.charset.StandardCharsets;
import java.security.MessageDigest;
import java.util.Arrays;

/**
 * Wi-Fi Aware (NAN) as one more direct video path for an active mirror session.
 *
 * <p>Only while a session runs, the phone publishes the "droidmirror" service.
 * Its service-specific info is a token derived from the session computer's
 * pairing key, so a computer only matches its own phone. The computer answers
 * with a follow-up proving the same key; only then does the phone accept a
 * NAN data path, secured with a passphrase that is also derived from that key.
 * TCP connections arriving on that data path are relayed to the existing
 * {@code droidmirror_video_upgrade} endpoint, so video still moves only after
 * the unchanged pairing-proof handshake (DMWIFI05/06) succeeds.
 */
final class WifiAwareEndpoint implements AutoCloseable {
    private static final String TAG = "DroidMirrorAware";
    static final String SERVICE = "droidmirror";
    private final Context context;
    private final byte[] key;
    private final Handler main = new Handler(Looper.getMainLooper());
    private volatile boolean closed;
    private WifiAwareSession aware;
    private PublishDiscoverySession publish;
    private ServerSocket server;
    private ConnectivityManager.NetworkCallback callback;
    private Thread acceptor;

    static boolean supported(Context context) {
        if (Build.VERSION.SDK_INT < 29 || !context.getPackageManager().hasSystemFeature(PackageManager.FEATURE_WIFI_AWARE)) return false;
        WifiAwareManager manager = context.getSystemService(WifiAwareManager.class);
        return manager != null && manager.isAvailable();
    }

    static byte[] derive(byte[] key, String label, int length) {
        try { return Arrays.copyOf(BleInputCrypto.hmac(key, label.getBytes(StandardCharsets.US_ASCII)), length); }
        catch (java.security.GeneralSecurityException impossible) { throw new IllegalStateException(impossible); }
    }
    /** Advertised in the publish SSI: identifies this pairing without revealing the key. */
    static byte[] serviceToken(byte[] key) { return derive(key, "DroidMirror Wi-Fi Aware service v1", 16); }
    /** The computer's follow-up message: proves it holds the same pairing key. */
    static byte[] requestToken(byte[] key) { return derive(key, "DroidMirror Wi-Fi Aware request v1", 16); }
    /** WPA passphrase for the NAN data path (8-63 printable characters). */
    static String passphrase(byte[] key) {
        byte[] bytes = derive(key, "DroidMirror Wi-Fi Aware passphrase v1", 24);
        return android.util.Base64.encodeToString(bytes, android.util.Base64.NO_WRAP | android.util.Base64.NO_PADDING);
    }

    WifiAwareEndpoint(Context context, byte[] key) {
        this.context = context.getApplicationContext();
        this.key = key.clone();
    }

    void start() {
        if (!supported(context)) { Log.i(TAG, "Wi-Fi Aware unavailable on this phone"); return; }
        if (Build.VERSION.SDK_INT >= 33 && context.checkSelfPermission(android.Manifest.permission.NEARBY_WIFI_DEVICES)
                != PackageManager.PERMISSION_GRANTED) {
            Log.i(TAG, "Wi-Fi Aware needs the Nearby Wi-Fi devices permission");
            return;
        }
        WifiAwareManager manager = context.getSystemService(WifiAwareManager.class);
        try {
            manager.attach(new AttachCallback() {
                @Override public void onAttached(WifiAwareSession session) {
                    if (closed) { session.close(); return; }
                    aware = session;
                    publish(session);
                }
                @Override public void onAttachFailed() { Log.w(TAG, "Wi-Fi Aware attach failed"); }
            }, main);
        } catch (SecurityException denied) { Log.w(TAG, "Wi-Fi Aware permission denied", denied); }
    }

    private void publish(WifiAwareSession session) {
        PublishConfig config = new PublishConfig.Builder().setServiceName(SERVICE)
            .setServiceSpecificInfo(serviceToken(key)).setPublishType(PublishConfig.PUBLISH_TYPE_UNSOLICITED).build();
        try {
            session.publish(config, new DiscoverySessionCallback() {
                @Override public void onPublishStarted(PublishDiscoverySession started) {
                    if (closed) { started.close(); return; }
                    publish = started;
                    Log.i(TAG, "Publishing DroidMirror over Wi-Fi Aware");
                }
                @Override public void onMessageReceived(PeerHandle peer, byte[] message) {
                    if (closed || publish == null) return;
                    if (!MessageDigest.isEqual(message, requestToken(key))) { Log.w(TAG, "Ignored an unauthenticated Wi-Fi Aware request"); return; }
                    acceptDataPath(peer);
                }
                @Override public void onSessionTerminated() { publish = null; }
            }, main);
        } catch (SecurityException denied) { Log.w(TAG, "Wi-Fi Aware publish denied", denied); }
    }

    private void acceptDataPath(PeerHandle peer) {
        try {
            if (server == null) {
                server = new ServerSocket(0);
                acceptor = new Thread(this::acceptLoop, "WifiAwareAccept");
                acceptor.start();
            }
            ConnectivityManager connectivity = context.getSystemService(ConnectivityManager.class);
            if (callback != null) connectivity.unregisterNetworkCallback(callback);
            WifiAwareNetworkSpecifier specifier = new WifiAwareNetworkSpecifier.Builder(publish, peer)
                .setPskPassphrase(passphrase(key)).setPort(server.getLocalPort()).build();
            NetworkRequest request = new NetworkRequest.Builder().addTransportType(NetworkCapabilities.TRANSPORT_WIFI_AWARE)
                .setNetworkSpecifier(specifier).build();
            callback = new ConnectivityManager.NetworkCallback() {
                @Override public void onAvailable(Network network) { Log.i(TAG, "Wi-Fi Aware data path up"); }
                @Override public void onLost(Network network) { Log.i(TAG, "Wi-Fi Aware data path lost"); }
            };
            connectivity.requestNetwork(request, callback);
            // Also tell the computer the port; some NAN stacks do not surface the port TLV.
            byte[] port = { (byte)(server.getLocalPort() >> 8), (byte) server.getLocalPort() };
            publish.sendMessage(peer, 1, port);
        } catch (IOException | RuntimeException failure) { Log.w(TAG, "Wi-Fi Aware data path setup failed", failure); }
    }

    private void acceptLoop() {
        while (!closed) {
            Socket socket;
            try { socket = server.accept(); } catch (IOException ended) { return; }
            // Only connections over the NAN data interface (IPv6 link-local) are relayed.
            if (!(socket.getInetAddress() instanceof Inet6Address) || !socket.getInetAddress().isLinkLocalAddress()) {
                try { socket.close(); } catch (IOException ignored) {}
                continue;
            }
            relay(socket);
        }
    }

    /** Pipes one TCP connection into the authenticated upgrade endpoint. */
    private void relay(Socket socket) {
        try {
            LocalSocket local = new LocalSocket();
            local.connect(new LocalSocketAddress("droidmirror_video_upgrade"));
            pump(socket.getInputStream(), local.getOutputStream(), socket, local);
            pump(local.getInputStream(), socket.getOutputStream(), socket, local);
        } catch (IOException failure) {
            try { socket.close(); } catch (IOException ignored) {}
        }
    }

    private static void pump(InputStream input, OutputStream output, Socket socket, LocalSocket local) {
        Thread thread = new Thread(() -> {
            byte[] buffer = new byte[65536];
            try {
                int count;
                while ((count = input.read(buffer)) > 0) { output.write(buffer, 0, count); output.flush(); }
            } catch (IOException ended) {
                // Either side closing ends the relay.
            } finally {
                try { socket.close(); } catch (IOException ignored) {}
                try { local.close(); } catch (IOException ignored) {}
            }
        }, "WifiAwareRelay");
        thread.setDaemon(true);
        thread.start();
    }

    @Override public void close() {
        closed = true;
        main.post(() -> {
            try {
                if (callback != null) context.getSystemService(ConnectivityManager.class).unregisterNetworkCallback(callback);
            } catch (RuntimeException ignored) {}
            callback = null;
            if (publish != null) publish.close();
            publish = null;
            if (aware != null) aware.close();
            aware = null;
        });
        try { if (server != null) server.close(); } catch (IOException ignored) {}
        Arrays.fill(key, (byte) 0);
    }
}
