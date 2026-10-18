package app.droidmirror.bluetooth;

import android.content.*;
import android.os.*;
import java.io.IOException;
import java.util.concurrent.*;
import rikka.shizuku.Shizuku;

/** App owns the shell listener through a death-tracked Binder token. */
final class ClassicL2capClient implements AutoCloseable {
    private final IBinder owner = new Binder();
    private final CompletableFuture<IClassicL2cap> ready = new CompletableFuture<>();
    private final Shizuku.UserServiceArgs args;
    private volatile IClassicL2cap remote;
    private volatile boolean closed;
    private volatile int transmitMtu;
    int transmitMtu() { return transmitMtu; }
    private final ServiceConnection connection = new ServiceConnection() {
        @Override public void onServiceConnected(ComponentName name, IBinder binder) {
            remote = IClassicL2cap.Stub.asInterface(binder); ready.complete(remote);
            if (closed) close();
        }
        @Override public void onServiceDisconnected(ComponentName name) {
            ready.completeExceptionally(new IOException("Classic L2CAP service disconnected"));
            remote = null;
        }
    };
    ClassicL2capClient(Context context) {
        args = new Shizuku.UserServiceArgs(new ComponentName(context.getPackageName(), ClassicL2capService.class.getName()))
            .daemon(true).processNameSuffix("classic_l2cap").debuggable(false).version(5);
        Shizuku.bindUserService(args, connection);
    }
    void listen(String peer) throws Exception {
        IClassicL2cap service = ready.get(10, TimeUnit.SECONDS);
        if (closed || !service.listen(owner, peer)) throw new IOException(service.getLastError());
    }
    ParcelFileDescriptor accept() throws Exception {
        IClassicL2cap service = remote;
        if (closed || service == null) throw new IOException("Classic L2CAP service unavailable");
        ParcelFileDescriptor result = service.accept(owner);
        if (result == null) throw new IOException(service.getLastError());
        transmitMtu = service.getTransmitMtu(owner);
        return result;
    }
    void disconnect() {
        try { if (remote != null) remote.disconnect(owner); } catch (RemoteException ignored) {}
    }
    @Override public void close() {
        closed = true;
        try { if (remote != null) remote.stop(owner); } catch (RemoteException ignored) {}
        new Handler(Looper.getMainLooper()).post(() -> {
            try { Shizuku.unbindUserService(args, connection, false); } catch (RuntimeException ignored) {}
        });
    }
}
