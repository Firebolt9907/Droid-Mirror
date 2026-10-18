package app.droidmirror.bluetooth;

import android.content.ComponentName;
import android.content.Context;
import android.content.ServiceConnection;
import android.os.Handler;
import android.os.IBinder;
import android.os.Looper;
import java.util.concurrent.CompletableFuture;
import java.util.concurrent.Executors;
import java.util.concurrent.ScheduledExecutorService;
import java.util.concurrent.TimeUnit;
import java.util.function.Consumer;
import rikka.shizuku.Shizuku;

/** One bounded, explicit operation, independent of the capture/display service. */
public final class HotspotClient implements AutoCloseable {
    private final Handler main = new Handler(Looper.getMainLooper());
    private final ScheduledExecutorService work = Executors.newScheduledThreadPool(2);
    private final Shizuku.UserServiceArgs args;
    private CompletableFuture<String> pending;
    private volatile boolean closed;
    private long lastStart;
    private final ServiceConnection connection = new ServiceConnection() {
        @Override public void onServiceConnected(ComponentName name, IBinder binder) {
            CompletableFuture<String> request = pending;
            if (closed || request == null || request.isDone()) { unbind(); return; }
            work.execute(() -> {
                if (closed || request.isDone()) return;
                try { request.complete(IHotspotBridge.Stub.asInterface(binder).startHotspot()); }
                catch (Exception failure) { request.complete("unavailable"); }
            });
        }
        @Override public void onServiceDisconnected(ComponentName name) {
            if (pending != null) pending.complete("unavailable");
        }
    };
    public HotspotClient(Context context) {
        args = new Shizuku.UserServiceArgs(new ComponentName(context.getPackageName(), HotspotBridgeService.class.getName()))
            .daemon(false).processNameSuffix("hotspot").debuggable(false).version(1);
    }
    // Called on the main thread, after authenticated BLE dispatch.
    public void start(Consumer<String> result) {
        if (closed) return;
        if (!ShizukuDisplayClient.authorized()) { result.accept("shizuku"); return; }
        long now = android.os.SystemClock.elapsedRealtime();
        if (pending != null || (lastStart != 0 && now - lastStart < 30000)) {
            result.accept("busy"); return;
        }
        lastStart = now;
        CompletableFuture<String> request = new CompletableFuture<>();
        pending = request;
        var timeout = work.schedule(() -> request.complete("timeout"), 28, TimeUnit.SECONDS);
        request.whenComplete((value, failure) -> main.post(() -> {
            timeout.cancel(false);
            unbind();
            if (pending == request) pending = null;
            if (!closed) result.accept(value == null ? "unavailable" : value);
        }));
        try { Shizuku.bindUserService(args, connection); }
        catch (RuntimeException unavailable) { request.complete("unavailable"); }
    }
    private void unbind() {
        try { Shizuku.unbindUserService(args, connection, false); } catch (RuntimeException ignored) {}
    }
    @Override public void close() {
        closed = true;
        if (pending != null) pending.complete("unavailable");
        unbind(); work.shutdownNow();
    }
}
