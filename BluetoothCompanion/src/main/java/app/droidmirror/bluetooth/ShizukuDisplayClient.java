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
    private final Context context;
    private final IBinder owner = new Binder();
    private final ScheduledExecutorService heartbeats = Executors.newSingleThreadScheduledExecutor();
    private final Handler main = new Handler(Looper.getMainLooper());
    private final Consumer<String> status;
    private final Consumer<Boolean> audit;
    private final BiConsumer<Integer, Boolean> ended;
    private final boolean panelOff;
    private final boolean blackoutOverlay;
    private volatile BlackoutMessage.State blackoutState;
    private String blackoutComputerName;
    private long nextBlackoutCheck;
    private volatile boolean auditKnown;
    private volatile boolean auditResult;
    private volatile boolean registered;
    private final CompletableFuture<IDisplayGuard> ready = new CompletableFuture<>();
    private final IStreamEvents observer = new IStreamEvents.Stub() {
        @Override public void onUnlockConfirmed() {
            try { SavedUnlockPin.completed(context); }
            catch (Exception failure) { status.accept("Could not update automatic unlock state. Save the PIN again on your phone."); }
        }
        @Override public void onEnded(int cause, boolean lockedAndAwake) {
            beginHapticRecovery();
            ended.accept(cause, lockedAndAwake);
        }
        @Override public void onHaptic() {
            if (closed || ending || lastVideo == 0) return;
            app.droidmirror.bluetooth.bridge.BridgeRuntime runtime =
                app.droidmirror.bluetooth.bridge.BridgeRuntime.Companion.getLive();
            if (runtime == null) return;
            try { runtime.sendEvent(new org.json.JSONObject().put("type", "haptic")); }
            catch (org.json.JSONException ignored) {}
        }
    };
    private final Shizuku.UserServiceArgs args;
    private volatile IDisplayGuard guard;
    private volatile boolean closed;
    private volatile long lastVideo;
    private volatile long lastPeerHeartbeat;
    private boolean attempted;
    private boolean armed;
    private boolean peerDelayReported;
    private boolean silentHapticsAttempted;
    private volatile boolean hapticForwarding;
    private volatile boolean ending;
    private final java.util.concurrent.atomic.AtomicBoolean earlyHapticRecovery = new java.util.concurrent.atomic.AtomicBoolean();
    private final java.util.concurrent.ExecutorService hapticWork = Executors.newSingleThreadExecutor();
    private final long started = SystemClock.elapsedRealtime();

    static boolean authorized() {
        try { return Shizuku.pingBinder() && Shizuku.getVersion() >= 13 && Shizuku.checkSelfPermission() == PackageManager.PERMISSION_GRANTED; }
        catch (RuntimeException error) { return false; }
    }
    static Shizuku.UserServiceArgs arguments(Context context) {
        return new Shizuku.UserServiceArgs(new ComponentName(context.getPackageName(), DisplayGuardService.class.getName()))
            // Bump when the embedded capture code changes: Shizuku daemons can
            // survive APK replacement and otherwise keep running the old code.
            .daemon(true).processNameSuffix("display_guard").debuggable(false).version(78);
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
        this.context = context.getApplicationContext();
        this.blackoutOverlay = this.context.getSharedPreferences("ready", Context.MODE_PRIVATE).getBoolean("blackoutOverlay", false);
        this.status = status; this.panelOff = panelOff && !blackoutOverlay; this.ended = ended; this.audit = audit;
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
        if (closed) throw new IllegalStateException("Mirror startup cancelled");
        if (SavedUnlockPin.paused(context)) status.accept("Automatic PIN entry is cooling down for 15 seconds; streaming remains available for manual unlock.");
        byte[] pin = SavedUnlockPin.beginAttempt(context);
        try {
            BlackoutMessage.State appearance = blackoutOverlay ? BlackoutMessage.read(context) : null;
            if (!remote.startCapture(owner, observer, output, controls, computerName, panelOff, pin, blackoutOverlay, blackoutOverlay ? BlackoutMessage.create(appearance, computerName) : null))
                throw new IllegalStateException(remote.getLastError());
            blackoutComputerName = computerName;
            blackoutState = appearance;
        } finally { if (pin != null) java.util.Arrays.fill(pin, (byte) 0); }
    }
    void localUse() {
        if (closed) return;
        beginHapticRecovery();
        try { heartbeats.execute(() -> {
            try { IDisplayGuard remote = guard; if (!closed && remote != null) remote.localUse(owner); }
            catch (RemoteException | RuntimeException ignored) {}
        }); } catch (java.util.concurrent.RejectedExecutionException ignored) {}
    }
    private void beginHapticRecovery() {
        ending = true;
        hapticForwarding = false;
        if (earlyHapticRecovery.compareAndSet(false, true)) {
            new Thread(() -> HapticVibrationRecovery.restoreSetting(context), "LocalHapticRecovery").start();
        }
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
                    String name = entry.getKey().getName();
                    if (!name.startsWith("Bluetooth") && !name.startsWith("Binder")
                            && !name.startsWith("Ble") && !name.equals("main")) continue;
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
                    ? "Streaming with phone panel off \u00b7 Shizuku recovery active"
                    : blackoutOverlay ? "Streaming with phone blackout overlay \u00b7 press power to use phone"
                    : "Streaming \u00b7 Shizuku local-use monitor active");
            } else if (armed && !remote.heartbeat(owner)) {
                status.accept("Screen-off lease ended; phone display restored or recovery is retrying."); close();
            }
            updateHaptics(remote);
            refreshBlackout(remote);
        } catch (RemoteException | RuntimeException error) {
            android.util.Log.e("DroidMirrorLease", "Session heartbeat failed", error);
            status.accept("Display guard unavailable; the shell watchdog must restore the panel."); close();
        }
    }
    private void updateHaptics(IDisplayGuard remote) {
        if (closed || ending || !armed) return;
        app.droidmirror.bluetooth.bridge.BridgeRuntime runtime =
            app.droidmirror.bluetooth.bridge.BridgeRuntime.Companion.getLive();
        boolean forwarding = runtime != null && runtime.canForwardHaptics();
        hapticForwarding = forwarding;
        if (forwarding == silentHapticsAttempted) return;
        silentHapticsAttempted = forwarding;
        hapticWork.execute(() -> {
            try {
                if (!forwarding) { remote.stopSilentHaptics(owner); HapticVibrationRecovery.restore(context); return; }
                if (closed || ending || !hapticForwarding) return;
                if (context.checkSelfPermission("android.permission.WRITE_SECURE_SETTINGS") != PackageManager.PERMISSION_GRANTED
                        && !remote.grantSecureSettings()) return;
                String original = HapticVibrationRecovery.prepare(context);
                if (closed || !hapticForwarding || !remote.startSilentHaptics(owner, original)) HapticVibrationRecovery.restore(context);
                if (closed || !hapticForwarding) { remote.stopSilentHaptics(owner); HapticVibrationRecovery.restore(context); }
            } catch (Exception failure) {
                HapticVibrationRecovery.restore(context);
                android.util.Log.w("DroidMirrorHaptics", "Silent haptics unavailable", failure);
            }
        });
    }
    private void refreshBlackout(IDisplayGuard remote) throws RemoteException {
        if (closed || !armed || blackoutState == null || SystemClock.elapsedRealtime() < nextBlackoutCheck) return;
        nextBlackoutCheck = SystemClock.elapsedRealtime() + 1000;
        try {
            BlackoutMessage.State appearance = BlackoutMessage.read(context);
            if (!appearance.matches(blackoutState)) {
                byte[] message = BlackoutMessage.create(appearance, blackoutComputerName);
                if (closed) return;
                if (remote.updateBlackout(owner, message)) blackoutState = appearance;
                else nextBlackoutCheck = SystemClock.elapsedRealtime() + 30000;
            }
        } catch (RuntimeException failure) {
            // An informational clock refresh must not terminate a healthy mirror.
            nextBlackoutCheck = SystemClock.elapsedRealtime() + 30000;
            android.util.Log.w("DroidMirrorBlackout", "AOD refresh deferred", failure);
        }
    }
    @Override public synchronized void close() {
        if (closed) { if (auditKnown) audit.accept(auditResult); return; }
        closed = true; // Suppress any future acquisition before queuing release.
        beginHapticRecovery();
        heartbeats.execute(() -> {
            try {
                IDisplayGuard remote = guard;
                auditResult = remote != null && remote.release(owner);
            } catch (RemoteException | RuntimeException ignored) {
                // Process-death/lease timeout recovery runs independently in the shell service.
            } finally {
                hapticWork.execute(() -> HapticVibrationRecovery.restore(context));
                hapticWork.shutdown();
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
                        work.shutdown();
                        main.post(() -> { try { Shizuku.unbindUserService(args, this, false); } catch (RuntimeException ignored) {} });
                    }
                });
            }
            @Override public void onServiceDisconnected(ComponentName name) {
                work.shutdown();
                status.accept("Could not reach the display guard.");
            }
        };
        try { Shizuku.bindUserService(args, connection); }
        catch (RuntimeException error) { status.accept("Could not start display guard recovery."); }
    }
}
