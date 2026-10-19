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
import android.os.ParcelFileDescriptor;
import android.os.SystemClock;
import java.util.concurrent.Executors;
import java.util.concurrent.ScheduledExecutorService;
import java.util.concurrent.TimeUnit;
import java.util.concurrent.CompletableFuture;
import java.util.function.Consumer;
import java.util.function.BiConsumer;
import rikka.shizuku.Shizuku;

/** App-side lease client. Recovery itself is implemented outside this process. */
final class ShizukuDisplayClient implements AutoCloseable {
    private final IBinder owner = new Binder();
    private final ScheduledExecutorService heartbeats = Executors.newSingleThreadScheduledExecutor();
    private final Handler main = new Handler(Looper.getMainLooper());
    private final Consumer<String> status;
    private final Consumer<Boolean> audit;
    private final BiConsumer<Integer, Boolean> ended;
    private final boolean panelOff;
    private volatile boolean auditKnown;
    private volatile boolean auditResult;
    private volatile boolean registered;
    private final CompletableFuture<IDisplayGuard> ready = new CompletableFuture<>();
    private final IStreamEvents observer = new IStreamEvents.Stub() {
        @Override public void onEnded(int cause, boolean lockedAndAwake) { ended.accept(cause, lockedAndAwake); }
    };
    private final Shizuku.UserServiceArgs args;
    private volatile IDisplayGuard guard;
    private volatile boolean closed;
    private volatile long lastVideo;
    private volatile long lastPeerHeartbeat;
    private boolean attempted;
    private boolean armed;
    private boolean peerDelayReported;
    private final long started = SystemClock.elapsedRealtime();

    static boolean authorized() {
        try { return Shizuku.pingBinder() && Shizuku.getVersion() >= 13 && Shizuku.checkSelfPermission() == PackageManager.PERMISSION_GRANTED; }
        catch (RuntimeException error) { return false; }
    }
    static Shizuku.UserServiceArgs arguments(Context context) {
        return new Shizuku.UserServiceArgs(new ComponentName(context.getPackageName(), DisplayGuardService.class.getName()))
            // Bump when the embedded capture code changes: Shizuku daemons can
            // survive APK replacement and otherwise keep running the old code.
            .daemon(true).processNameSuffix("display_guard").debuggable(false).version(49);
    }
    private final ServiceConnection connection = new ServiceConnection() {
        @Override public void onServiceConnected(ComponentName name, IBinder binder) {
            guard = IDisplayGuard.Stub.asInterface(binder);
            ready.complete(guard);
            // Shizuku is iterating its connection listeners during this callback.
            // Remove ours after dispatch to avoid mutating that collection.
            if (closed) main.post(ShizukuDisplayClient.this::unbind);
        }
        @Override public void onServiceDisconnected(ComponentName name) {
            guard = null;
            ready.completeExceptionally(new IllegalStateException("Display guard disconnected"));
            if (closed) return;
            close();
            status.accept("Shizuku display guard disconnected. Screen restoration cannot be confirmed.");
        }
    };
    ShizukuDisplayClient(Context context, boolean panelOff, Consumer<String> status,
                         BiConsumer<Integer, Boolean> ended, Consumer<Boolean> audit) {
        this.status = status; this.panelOff = panelOff; this.ended = ended; this.audit = audit;
        args = arguments(context);
        if (!authorized()) { closed = true; auditKnown = true; heartbeats.shutdown();
            ready.completeExceptionally(new IllegalStateException("Shizuku unavailable")); status.accept("Shizuku is not authorized; phone display stays on."); return; }
        try { Shizuku.bindUserService(args, connection); }
        catch (RuntimeException error) { closed = true; auditKnown = true; heartbeats.shutdown();
            ready.completeExceptionally(new IllegalStateException("Shizuku unavailable")); status.accept("Shizuku guard could not start; phone display stays on."); return; }
        heartbeats.scheduleWithFixedDelay(this::update, 250, 250, TimeUnit.MILLISECONDS);
    }
    byte[] phoneAppearance() throws Exception {
        return ready.get(10, TimeUnit.SECONDS).phoneAppearance();
    }
    void startVideo(ParcelFileDescriptor output, ParcelFileDescriptor controls, String computerName) throws Exception {
        IDisplayGuard remote = ready.get(10, TimeUnit.SECONDS);
        if (closed || !remote.startCapture(owner, observer, output, controls, computerName, panelOff)) throw new IllegalStateException(remote.getLastError());
    }
    void localUse() {
        if (closed) return;
        try { heartbeats.execute(() -> {
            try { IDisplayGuard remote = guard; if (!closed && remote != null) remote.localUse(owner); }
            catch (RemoteException | RuntimeException ignored) {}
        }); } catch (java.util.concurrent.RejectedExecutionException ignored) {}
    }
    void upgradeVideo(WirelessVideoProfile profile) throws java.io.IOException {
        IDisplayGuard remote = guard;
        try {
            if (closed || remote == null || !remote.upgradeVideo(owner, profile.maxSize, profile.fps, profile.bitRate))
                throw new java.io.IOException("Wi-Fi video quality upgrade unavailable");
        } catch (RemoteException error) { throw new java.io.IOException(error); }
    }
    void restoreBluetoothVideo() throws java.io.IOException {
        IDisplayGuard remote=guard;
        try {
            if (closed || remote==null || !remote.restoreBluetoothVideo(owner))
                throw new java.io.IOException("Bluetooth video profile restore unavailable");
        } catch (RemoteException error) { throw new java.io.IOException(error); }
    }
    boolean startAudio(ParcelFileDescriptor output) throws RemoteException {
        IDisplayGuard remote = guard;
        return !closed && remote != null && remote.startAudio(owner, output);
    }
    void stopAudio() {
        try { IDisplayGuard remote = guard; if (remote != null) remote.stopAudio(owner); }
        catch (RemoteException ignored) {}
    }
    void frameSent() {
        if (lastVideo == 0) android.util.Log.i("DroidMirrorLease", "First video frame transmitted");
        lastVideo = SystemClock.elapsedRealtime();
    }
    void peerAlive() { lastPeerHeartbeat = SystemClock.elapsedRealtime(); }
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
            if (progress == 0) return; // Startup OFF has its own bounded guard deadline.
            if (lastPeerHeartbeat == 0) return;
            long peerAge = SystemClock.elapsedRealtime() - lastPeerHeartbeat;
            boolean access = authorized();
            if (peerAge <= 2000) peerDelayReported = false;
            if (peerAge > 2000 && !peerDelayReported) {
                peerDelayReported = true;
                android.util.Log.w("DroidMirrorLease", "Peer heartbeat age=" + peerAge + "ms; Shizuku authorized=" + access);
                for (java.util.Map.Entry<Thread, StackTraceElement[]> entry : Thread.getAllStackTraces().entrySet()) {
                    if (!entry.getKey().getName().startsWith("Bluetooth")) continue;
                    android.util.Log.w("DroidMirrorLease", entry.getKey().getName() + " " + entry.getKey().getState()
                        + " " + java.util.Arrays.toString(entry.getValue()));
                }
            }
            if (peerAge > 5000 || !access) {
                status.accept("Mac connection or Shizuku access stalled; restoring phone display."); close(); return;
            }
            if (!attempted) {
                android.util.Log.i("DroidMirrorLease", "Acquiring session lease");
                attempted = true;
                armed = remote.acquire(owner, observer, panelOff);
                registered = armed;
                if (!armed) {
                    status.accept("Screen-off unavailable: " + remote.getLastError()); close(); return;
                }
                String error = remote.getLastError();
                status.accept(!error.isEmpty() ? "Display stays on: " + error : panelOff
                    ? "Streaming with phone panel off · Shizuku recovery active"
                    : "Streaming · Shizuku local-use monitor active");
            } else if (armed && !remote.heartbeat(owner)) {
                status.accept("Screen-off lease ended; phone display restored or recovery is retrying."); close();
            }
        } catch (RemoteException | RuntimeException error) {
            android.util.Log.e("DroidMirrorLease", "Session heartbeat failed", error);
            status.accept("Display guard unavailable; the shell watchdog must restore the panel."); close();
        }
    }
    @Override public synchronized void close() {
        if (closed) { if (auditKnown) audit.accept(auditResult); return; }
        closed = true; // Suppress any future acquisition before queuing release.
        heartbeats.execute(() -> {
            try {
                IDisplayGuard remote = guard;
                auditResult = remote != null && remote.release(owner);
            } catch (RemoteException | RuntimeException ignored) {
                // Process-death/lease timeout recovery runs independently in the shell service.
            } finally {
                auditKnown = true; audit.accept(auditResult);
                main.post(this::unbind);
            }
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
                    main.post(() -> { try { Shizuku.unbindUserService(args, this, false); } catch (RuntimeException ignored) {} });
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
