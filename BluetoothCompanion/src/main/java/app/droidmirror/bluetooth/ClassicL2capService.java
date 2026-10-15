package app.droidmirror.bluetooth;

import android.annotation.SuppressLint;
import android.bluetooth.*;
import android.content.Context;
import android.os.IBinder;
import android.os.ParcelFileDescriptor;
import java.io.*;
import java.lang.reflect.InvocationTargetException;

/** Shell-owned authenticated Classic L2CAP socket; app receives a video-only write pipe. */
@SuppressLint({"PrivateApi", "BlockedPrivateApi", "SoonBlockedPrivateApi", "DiscouragedPrivateApi"})
public final class ClassicL2capService extends IClassicL2cap.Stub {
    static final int PSM = 0x1001;
    private IBinder owner;
    private IBinder.DeathRecipient death;
    private String peer;
    private BluetoothServerSocket listener;
    private BluetoothSocket connection;
    private ParcelFileDescriptor relay;
    private String error = "";

    public ClassicL2capService() {}
    public ClassicL2capService(Context context) { this(); }

    @Override public synchronized boolean listen(IBinder token, String address) {
        if (token == null || !BluetoothAdapter.checkBluetoothAddress(address)) { error = "Invalid selected Mac"; return false; }
        if (owner == token && listener != null && address.equals(peer)) return true;
        if (owner != null) { error = "Classic L2CAP listener already owned"; return false; }
        long identity = android.os.Binder.clearCallingIdentity();
        try {
            PrivilegedCapture.initialize();
            // app_process does not perform the framework initialization used by normal apps.
            if (android.os.Build.VERSION.SDK_INT >= 31) {
                Class<?> init = Class.forName("android.bluetooth.BluetoothFrameworkInitializer");
                if (init.getMethod("getBluetoothServiceManager").invoke(null) == null) {
                    Class<?> manager = Class.forName("android.os.BluetoothServiceManager");
                    init.getMethod("setBluetoothServiceManager", manager).invoke(null, manager.getConstructor().newInstance());
                }
            }
            Context shell = com.genymobile.scrcpy.FakeContext.get().getBaseContext().createPackageContext("com.android.shell", 0);
            BluetoothAdapter adapter = shell.getSystemService(BluetoothManager.class).getAdapter();
            if (adapter == null || !adapter.isEnabled()) throw new IOException("Enable Bluetooth on the phone");
            BluetoothDevice device = adapter.getRemoteDevice(address);
            if (device.getBondState() != BluetoothDevice.BOND_BONDED) throw new IOException("Pair the selected Mac first");
            // Hidden Classic API, not the public LE-only listenUsingL2capChannel().
            listener = (BluetoothServerSocket) BluetoothAdapter.class.getMethod("listenUsingL2capOn", int.class).invoke(adapter, PSM);
            owner = token; peer = address; death = () -> stop(token);
            token.linkToDeath(death, 0);
            if (!token.isBinderAlive()) throw new IOException("Listener owner died");
            error = "";
            android.util.Log.i("DroidMirrorL2cap", "Authenticated Classic L2CAP listener ready on PSM 0x1001");
            return true;
        } catch (SecurityException denied) {
            error = "Classic L2CAP Bluetooth permission denied: " + denied.getMessage();
            closeListener(); return false;
        } catch (Exception failure) {
            Throwable cause = failure instanceof InvocationTargetException ? failure.getCause() : failure;
            error = "Classic L2CAP unavailable: " + cause;
            closeListener(); return false;
        } finally { android.os.Binder.restoreCallingIdentity(identity); }
    }

    @Override public ParcelFileDescriptor accept(IBinder token) {
        BluetoothServerSocket server;
        synchronized (this) {
            if (owner != token || listener == null || connection != null) { error = "Classic L2CAP listener not ready"; return null; }
            server = listener;
        }
        long identity = android.os.Binder.clearCallingIdentity();
        try {
            while (true) {
                BluetoothSocket candidate = server.accept();
                synchronized (this) {
                    if (owner != token || listener != server) { candidate.close(); return null; }
                    BluetoothDevice device = candidate.getRemoteDevice();
                    if (!peer.equals(device.getAddress()) || device.getBondState() != BluetoothDevice.BOND_BONDED) {
                        candidate.close(); continue;
                    }
                    ParcelFileDescriptor[] pair = ParcelFileDescriptor.createPipe();
                    connection = candidate; relay = pair[0];
                    InputStream localInput = new ParcelFileDescriptor.AutoCloseInputStream(ParcelFileDescriptor.dup(relay.getFileDescriptor()));
                    rejectIncoming(candidate);
                    pump(candidate, localInput, candidate.getOutputStream(), "AppToL2cap");
                    android.util.Log.i("DroidMirrorL2cap", "Classic L2CAP connected; TX MTU=" + candidate.getMaxTransmitPacketSize()
                        + ", RX MTU=" + candidate.getMaxReceivePacketSize());
                    return pair[1];
                }
            }
        } catch (SecurityException denied) {
            synchronized (this) { error = "Classic L2CAP Bluetooth permission denied: " + denied.getMessage(); closeConnection(); }
            return null;
        } catch (Exception failure) {
            synchronized (this) { error = "Classic L2CAP accept failed: " + failure; closeConnection(); }
            return null;
        } finally { android.os.Binder.restoreCallingIdentity(identity); }
    }

    // No application payload may travel Mac-to-phone on Classic, even accidentally.
    // Bluetooth link-layer acknowledgements remain the operating system's responsibility.
    private void rejectIncoming(BluetoothSocket socket) {
        new Thread(() -> {
            try {
                if (socket.getInputStream().read() != -1)
                    android.util.Log.w("DroidMirrorL2cap", "Rejected unexpected reverse Classic payload");
            } catch (IOException ignored) {
            } finally {
                synchronized (this) { if (connection == socket) closeConnection(); }
            }
        }, "L2capReverseGuard").start();
    }
    private void pump(BluetoothSocket socket, InputStream input, OutputStream output, String name) {
        new Thread(() -> {
            try (InputStream source = input; OutputStream destination = output) {
                int mtu = socket.getMaxTransmitPacketSize();
                // Batch whole negotiated SDUs without waiting for a packet/ACK.
                int bufferSize = mtu > 0 && mtu <= 16384 ? mtu * Math.min(6, 16384 / mtu) : 4096;
                byte[] bytes = new byte[bufferSize]; int count;
                while ((count = source.read(bytes)) != -1) { destination.write(bytes, 0, count); destination.flush(); }
            } catch (IOException failure) {
                android.util.Log.d("DroidMirrorL2cap", name + " ended: " + failure.getMessage());
            } finally {
                synchronized (this) { if (connection == socket) closeConnection(); }
            }
        }, name).start();
    }
    private void closeConnection() {
        try { if (connection != null) connection.close(); } catch (IOException ignored) {}
        try { if (relay != null) relay.close(); } catch (IOException ignored) {}
        connection = null; relay = null;
    }
    private void closeListener() {
        closeConnection();
        try { if (listener != null) listener.close(); } catch (IOException ignored) {}
        listener = null;
        try { if (owner != null && death != null) owner.unlinkToDeath(death, 0); } catch (RuntimeException ignored) {}
        owner = null; death = null;
    }
    @Override public synchronized void disconnect(IBinder token) { if (owner == token) closeConnection(); }
    @Override public synchronized void stop(IBinder token) { if (owner == token) closeListener(); }
    @Override public synchronized int getTransmitMtu(IBinder token) {
        return owner == token && connection != null ? connection.getMaxTransmitPacketSize() : 0;
    }
    @Override public synchronized String getLastError() { return error; }
    @Override public synchronized void destroy() { closeListener(); System.exit(0); }
}
