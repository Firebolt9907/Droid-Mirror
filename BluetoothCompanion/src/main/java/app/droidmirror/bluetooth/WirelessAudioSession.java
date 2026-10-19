package app.droidmirror.bluetooth;

import android.content.Context;
import android.media.*;
import android.net.ConnectivityManager;
import android.net.NetworkCapabilities;
import android.os.Build;
import android.os.ParcelFileDescriptor;
import java.io.*;
import java.nio.ByteBuffer;
import java.util.List;

/** One opt-in stream tied to the authenticated wireless video session. */
final class WirelessAudioSession implements WirelessVideoUpgrade.AudioSession, WirelessAudioUpgrade.Session {
    private final AudioManager manager;
    private final ConnectivityManager connectivity;
    private final BluetoothWire wire;
    private final ShizukuDisplayClient guard;
    private volatile ParcelFileDescriptor reader;
    private volatile boolean playing;
    private volatile OutputStream independentOutput;
    private volatile boolean failed;
    private long lastState;
    WirelessAudioSession(Context context, BluetoothWire wire, ShizukuDisplayClient guard) {
        manager = context.getSystemService(AudioManager.class);
        connectivity = context.getSystemService(ConnectivityManager.class);
        this.wire = wire; this.guard = guard;
    }
    private static boolean bluetooth(AudioDeviceInfo device) {
        int type = device.getType();
        return type == AudioDeviceInfo.TYPE_BLUETOOTH_A2DP || type == AudioDeviceInfo.TYPE_BLUETOOTH_SCO
            || type == AudioDeviceInfo.TYPE_HEARING_AID || type == AudioDeviceInfo.TYPE_BLE_HEADSET
            || type == AudioDeviceInfo.TYPE_BLE_SPEAKER || type == AudioDeviceInfo.TYPE_BLE_BROADCAST;
    }
    private boolean eligible() {
        if (Build.VERSION.SDK_INT < 31 || manager == null) return false;
        try {
            NetworkCapabilities network = connectivity == null ? null
                : connectivity.getNetworkCapabilities(connectivity.getActiveNetwork());
            // A VPN/direct-IP video path can also run over cellular. Audio is
            // deliberately offered only when the phone's active path is Wi-Fi.
            if (network == null || !network.hasTransport(NetworkCapabilities.TRANSPORT_WIFI)) return false;
            if (manager.getMode() != AudioManager.MODE_NORMAL) return false;
            // REMOTE_SUBMIX temporarily changes routing while forwarding. In that
            // case a newly attached Bluetooth output takes priority immediately.
            if (Build.VERSION.SDK_INT >= 33 && reader == null) {
                List<AudioDeviceInfo> route = manager.getAudioDevicesForAttributes(
                    new AudioAttributes.Builder().setUsage(AudioAttributes.USAGE_MEDIA).build());
                if (route.isEmpty()) return false;
                for (AudioDeviceInfo device : route) if (bluetooth(device)) return false;
            } else {
                // Older Android has no public media-route query. Be conservative
                // rather than hijacking a connected headset.
                for (AudioDeviceInfo device : manager.getDevices(AudioManager.GET_DEVICES_OUTPUTS))
                    if (bluetooth(device)) return false;
            }
            return manager.isMusicActive();
        } catch (RuntimeException unavailable) { return false; }
    }
    @Override public void poll() throws IOException {
        boolean available = eligible();
        if (!available && reader != null) stop();
        long now = android.os.SystemClock.elapsedRealtime();
        if (now - lastState < 500) return;
        lastState = now;
        wire.audioRecord(6, new byte[]{(byte)((available ? 1 : 0) | (playing ? 2 : 0) | (failed ? 4 : 0))});
    }
    @Override public boolean ready() { return wire.isWireless(); }
    @Override public synchronized boolean start(OutputStream output) {
        if (reader != null) return false;
        independentOutput=output;
        start();
        if (reader == null) independentOutput=null;
        return reader != null;
    }
    @Override public synchronized void start() {
        if (reader != null || !wire.isWireless() || !eligible()) return;
        failed = false;
        ParcelFileDescriptor[] pipe = null;
        try {
            pipe = ParcelFileDescriptor.createPipe();
            if (!guard.startAudio(pipe[1])) throw new IOException("Output capture unavailable");
            ParcelFileDescriptor input = pipe[0]; reader = input;
            new Thread(() -> relay(input), "WirelessAudio").start();
        } catch (Exception error) {
            failed = true;
            if (pipe != null) for (ParcelFileDescriptor fd : pipe) try { fd.close(); } catch (IOException ignored) {}
            guard.stopAudio();
        } finally {
            if (pipe != null) try { pipe[1].close(); } catch (IOException ignored) {}
        }
    }
    private void relay(ParcelFileDescriptor descriptor) {
        final OutputStream lane=independentOutput;
        final DataOutputStream independent=lane==null ? null : new DataOutputStream(new BufferedOutputStream(lane,8192));
        try (DataInputStream input = new DataInputStream(new ParcelFileDescriptor.AutoCloseInputStream(descriptor))) {
            if (input.readInt() != 0x00726177) throw new IOException("Expected raw audio");
            while (reader == descriptor && wire.isWireless()) {
                long pts = input.readLong(); int count = input.readInt();
                if (pts < 0 || count <= 0 || count > 4096 || count % 4 != 0) throw new IOException("Invalid PCM packet");
                byte[] record = new byte[8 + count];
                ByteBuffer.wrap(record).putLong(pts); input.readFully(record, 8, count);
                if (reader != descriptor) break;
                if (lane == null) wire.audioRecord(7, record);
                else {
                    // No video monitor, ACK window or large video writes ahead of PCM.
                    // Coalesce header and PCM into one socket write instead of
                    // feeding tiny writes into ADB/TCP's forwarding scheduler.
                    independent.writeByte(7); independent.writeInt(record.length);
                    independent.write(record); independent.flush();
                }
                playing = true;
            }
        } catch (IOException error) {
            if (reader == descriptor) {
                failed = true;
                android.util.Log.w("DroidMirrorAudio", "Audio forwarding stopped", error);
            }
        } finally {
            synchronized (this) { if (reader == descriptor) stop(); }
        }
    }
    @Override public synchronized void stop() {
        ParcelFileDescriptor input = reader; reader = null; playing = false; independentOutput=null;
        if (input != null) {
            try { input.close(); } catch (IOException ignored) {}
            guard.stopAudio();
        }
    }
}
