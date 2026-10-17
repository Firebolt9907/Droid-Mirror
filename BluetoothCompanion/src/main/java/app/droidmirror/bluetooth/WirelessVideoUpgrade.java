package app.droidmirror.bluetooth;

import android.net.LocalServerSocket;
import android.net.LocalSocket;
import java.io.*;
import java.security.MessageDigest;
import java.security.SecureRandom;

/** Active-session-only local endpoint reached through the paired Iroh tunnel. */
final class WirelessVideoUpgrade implements AutoCloseable {
    private final LocalServerSocket listener;
    private volatile LocalSocket candidate;
    private volatile boolean closed;
    private volatile byte[] activeNonce;
    private final BluetoothWire wire;
    private final QualityUpgrade quality;
    private final Object transition=new Object();
    private final java.util.concurrent.atomic.AtomicBoolean recovering=new java.util.concurrent.atomic.AtomicBoolean();
    // A null profile restores the original Bluetooth encoder settings.
    interface QualityUpgrade { void apply(WirelessVideoProfile profile) throws IOException; }

    WirelessVideoUpgrade(BluetoothWire wire, byte[] key, QualityUpgrade quality) throws IOException {
        this.wire=wire; this.quality=quality;
        listener = new LocalServerSocket("droidmirror_video_upgrade");
        new Thread(() -> {
            try {
                while (!closed) {
                    LocalSocket socket = listener.accept();
                    candidate = socket;
                    if (closed) { socket.close(); break; }
                    boolean committed = false;
                    try {
                        socket.setSoTimeout(2000);
                        DataInputStream input = new DataInputStream(socket.getInputStream());
                        OutputStream output = socket.getOutputStream();
                        byte[] nonce = new byte[32]; new SecureRandom().nextBytes(nonce);
                        output.write("DMWIFI03".getBytes(java.nio.charset.StandardCharsets.US_ASCII));
                        output.write(nonce); output.flush();
                        byte[] requested = new byte[WirelessVideoProfile.WIRE_SIZE]; input.readFully(requested);
                        byte[] proof = new byte[32]; input.readFully(proof);
                        if (!MessageDigest.isEqual(proof, WirelessUpgradeAuth.proof(key, "client", nonce, requested))) continue;
                        WirelessVideoProfile profile = WirelessVideoProfile.parse(requested);
                        activeNonce=nonce;
                        committed = wire.upgrade(output, key, nonce, requested);
                        if (committed) {
                            // The receiver must drain the old Classic cutoff first.
                            // Only then may larger frames and bitrate enter Wi-Fi.
                            socket.setSoTimeout(8000);
                            if (input.readUnsignedByte() != 1) throw new IOException("Wi-Fi receiver did not confirm handoff");
                            synchronized (transition) {
                                if (recovering.get() || !wire.isWireless()) throw new IOException("Wi-Fi handoff was cancelled");
                                wire.enableWirelessThroughput();
                                quality.apply(profile);
                            }
                            // Bluetooth stays idle until the Mac requests recovery over BLE.
                            while (!closed && wire.isWireless()) {
                                wire.wirelessHeartbeat();
                                try { Thread.sleep(1000); }
                                catch (InterruptedException interrupted) { Thread.currentThread().interrupt(); return; }
                            }
                        }
                    } catch (IOException unavailable) {
                        // Probes are harmless before commit. After commit, the
                        // Mac restarts Classic video through the authenticated BLE path.
                        if (committed) abort(socket);
                    } finally {
                        abort(socket);
                        if (candidate==socket) candidate=null;
                    }
                    // A lost ADB transport must not accept another upgrade until
                    // the BLE-requested Bluetooth recovery has finished.
                    while (!closed && wire.isWireless()) {
                        try { Thread.sleep(50); }
                        catch (InterruptedException interrupted) { Thread.currentThread().interrupt(); return; }
                    }
                }
            } catch (IOException stopped) {
                // Closing the session interrupts accept/read/write.
            } finally { try { listener.close(); } catch (IOException ignored) {} }
        }, "WirelessVideoUpgrade").start();
    }

    void fallback(byte[] nonce, long received) {
        byte[] active=activeNonce;
        if (closed || active==null || !MessageDigest.isEqual(active,nonce) || !wire.isWireless() || !recovering.compareAndSet(false,true)) return;
        // Do not wait for the wire monitor: its writer may be blocked in ADB.
        LocalSocket socket=candidate;
        abort(socket);
        new Thread(() -> {
            try {
                synchronized (transition) {
                    quality.apply(null);
                    wire.fallback(received);
                }
            } catch (IOException failed) { close(); }
            finally { recovering.set(false); }
        },"BluetoothVideoFallback").start();
    }

    private static void abort(LocalSocket socket) {
        if (socket==null) return;
        // close() alone need not interrupt a native write already using the fd.
        // shutdown releases that write before fallback needs the wire monitor.
        try { socket.shutdownOutput(); } catch (IOException ignored) {}
        try { socket.shutdownInput(); } catch (IOException ignored) {}
        try { socket.close(); } catch (IOException ignored) {}
    }

    @Override public void close() {
        closed = true;
        try { listener.close(); } catch (IOException ignored) {}
        abort(candidate);
    }
}
