package app.droidmirror.bluetooth;

import android.content.ComponentName;
import android.content.Context;
import android.content.ServiceConnection;
import android.content.pm.PackageManager;
import android.os.Binder;
import android.os.Handler;
import android.os.IBinder;
import android.os.Looper;
import android.os.RemoteException;
import android.os.SystemClock;
import java.util.concurrent.Executors;
import java.util.concurrent.ScheduledExecutorService;
import java.util.concurrent.TimeUnit;
import java.util.function.Consumer;
import rikka.shizuku.Shizuku;

/** App-side lease client. Recovery itself is implemented outside this process. */
final class ShizukuDisplayClient implements AutoCloseable {
    private final IBinder owner = new Binder();
    private final ScheduledExecutorService heartbeats = Executors.newSingleThreadScheduledExecutor();
    private final Handler main = new Handler(Looper.getMainLooper());
    private final Consumer<String> status;
    private final Shizuku.UserServiceArgs args;
    private volatile IDisplayGuard guard;
    private volatile boolean closed;
    private volatile long lastVideo;
    private boolean attempted;
    private boolean armed;
    private final long started = SystemClock.elapsedRealtime();

    static boolean authorized() {
        try { return Shizuku.pingBinder() && Shizuku.getVersion() >= 13 && Shizuku.checkSelfPermission() == PackageManager.PERMISSION_GRANTED; }
        catch (RuntimeException error) { return false; }
    }
    private static Shizuku.UserServiceArgs arguments(Context context) {
        return new Shizuku.UserServiceArgs(new ComponentName(context.getPackageName(), DisplayGuardService.class.getName()))
            .daemon(true).processNameSuffix("display_guard").debuggable(false).version(2);
    }
    private final ServiceConnection connection = new ServiceConnection() {
        @Override public void onServiceConnected(ComponentName name, IBinder binder) {
            guard = IDisplayGuard.Stub.asInterface(binder);
            if (closed) unbind();
        }
        @Override public void onServiceDisconnected(ComponentName name) {
            guard = null;
            if (closed) return;
            close();
            status.accept("Shizuku display guard disconnected. Screen restoration cannot be confirmed.");
        }
    };
    ShizukuDisplayClient(Context context, Consumer<String> status) {
        this.status = status;
        args = arguments(context);
        if (!authorized()) { closed = true; heartbeats.shutdown(); status.accept("Shizuku is not authorized; phone display stays on."); return; }
        try { Shizuku.bindUserService(args, connection); }
        catch (RuntimeException error) { closed = true; heartbeats.shutdown(); status.accept("Shizuku guard could not start; phone display stays on."); return; }
        heartbeats.scheduleWithFixedDelay(this::update, 250, 250, TimeUnit.MILLISECONDS);
    }
    void frameSent() { lastVideo = SystemClock.elapsedRealtime(); }
    private void update() {
        if (closed) return;
        IDisplayGuard remote = guard;
        try {
            if (remote == null) {
                if (SystemClock.elapsedRealtime() - started > 10000) {
                    status.accept("Shizuku guard timed out; phone display stays on."); close();
                }
                return;
            }
            long progress = lastVideo;
            if (progress == 0) return; // Never OFF before an actual media frame was sent.
            if (SystemClock.elapsedRealtime() - progress > 1500 || !authorized()) {
                status.accept("Video or Shizuku access stalled; restoring phone display."); close(); return;
            }
            if (!attempted) {
                attempted = true;
                armed = remote.acquire(owner);
                if (!armed) {
                    status.accept("Screen-off unavailable: " + remote.getLastError()); close(); return;
                }
                status.accept("Streaming with phone panel off · Shizuku recovery active");
            } else if (armed && !remote.heartbeat(owner)) {
                status.accept("Screen-off lease ended; phone display restored or recovery is retrying."); close();
            }
        } catch (RemoteException | RuntimeException error) {
            status.accept("Display guard unavailable; the shell watchdog must restore the panel."); close();
        }
    }
    @Override public synchronized void close() {
        if (closed) return;
        closed = true; // Suppress any future acquisition before queuing release.
        heartbeats.execute(() -> {
            try {
                IDisplayGuard remote = guard;
                if (remote != null) remote.release(owner);
            } catch (RemoteException | RuntimeException ignored) {
                // Process-death/lease timeout recovery runs independently in the shell service.
            } finally { main.post(this::unbind); }
        });
        heartbeats.shutdown(); // Let an in-flight acquire finish, then restore it in order.
    }
    private void unbind() {
        try { Shizuku.unbindUserService(args, connection, false); }
        catch (RuntimeException ignored) {}
    }
    static void restoreDisplay(Context context, Consumer<String> status) {
        if (!authorized()) { status.accept("Start Shizuku and grant permission first."); return; }
        Shizuku.UserServiceArgs args = arguments(context);
        Handler main = new Handler(Looper.getMainLooper());
        ScheduledExecutorService work = Executors.newSingleThreadScheduledExecutor();
        ServiceConnection connection = new ServiceConnection() {
            @Override public void onServiceConnected(ComponentName name, IBinder binder) {
                if (work.isShutdown()) {
                    try { Shizuku.unbindUserService(args, this, false); } catch (RuntimeException ignored) {}
                    return;
                }
                work.execute(() -> {
                    try {
                        IDisplayGuard remote = IDisplayGuard.Stub.asInterface(binder);
                        status.accept(remote.restoreDisplay() ? "Phone display restored." : remote.getLastError());
                    } catch (RemoteException | RuntimeException error) { status.accept("Could not reach the display guard."); }
                    finally {
                        main.post(() -> { try { Shizuku.unbindUserService(args, this, false); } catch (RuntimeException ignored) {} });
                        work.shutdownNow();
                    }
                });
            }
            @Override public void onServiceDisconnected(ComponentName name) { work.shutdownNow(); status.accept("Display guard disconnected."); }
        };
        try {
            work.schedule(() -> {
                status.accept("Display guard connection timed out.");
                main.post(() -> { try { Shizuku.unbindUserService(args, connection, false); } catch (RuntimeException ignored) {} });
                work.shutdownNow();
            }, 10, TimeUnit.SECONDS);
            Shizuku.bindUserService(args, connection);
        } catch (RuntimeException error) { work.shutdownNow(); status.accept("Could not start the display guard."); }
    }
}
