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
import org.json.JSONObject;

/** One bounded, explicit operation, independent of the capture/display service. */
public final class HotspotClient implements AutoCloseable {
    private final Handler main = new Handler(Looper.getMainLooper());
    private final ScheduledExecutorService work = Executors.newScheduledThreadPool(2);
    private final Shizuku.UserServiceArgs args;
    private CompletableFuture<String> pending;
    private volatile boolean closed;
    private long lastStart;
    private boolean starting;
    private final ServiceConnection connection = new ServiceConnection() {
        @Override public void onServiceConnected(ComponentName name, IBinder binder) {
            CompletableFuture<String> request = pending;
            if (closed || request == null || request.isDone()) { unbind(); return; }
            boolean enable = starting;
            work.execute(() -> {
                if (closed || request.isDone()) return;
                try {
                    IHotspotBridge bridge = IHotspotBridge.Stub.asInterface(binder);
                    String status = enable ? bridge.startHotspot() : bridge.stopHotspot();
                    JSONObject response = new JSONObject().put("status", status);
                    if ("started".equals(status)) response.put("ssid", bridge.hotspotSSID());
                    request.complete(response.toString());
                }
                catch (Exception failure) { request.complete("unavailable"); }
            });
        }
        @Override public void onServiceDisconnected(ComponentName name) {
            if (pending != null) pending.complete("unavailable");
        }
    };
    public HotspotClient(Context context) {
        args = new Shizuku.UserServiceArgs(new ComponentName(context.getPackageName(), HotspotBridgeService.class.getName()))
            .daemon(false).processNameSuffix("hotspot").debuggable(false).version(2);
    }
    // Called on the main thread, after authenticated BLE dispatch.
    public void setEnabled(boolean enabled, Consumer<JSONObject> result) {
        if (closed) return;
        if (!ShizukuDisplayClient.authorized()) { result.accept(response("shizuku")); return; }
        long now = android.os.SystemClock.elapsedRealtime();
        if (pending != null || (enabled && lastStart != 0 && now - lastStart < 30000)) {
            result.accept(response("busy")); return;
        }
        starting = enabled;
        if (enabled) lastStart = now;
        CompletableFuture<String> request = new CompletableFuture<>();
        pending = request;
        var timeout = work.schedule(() -> request.complete("timeout"), 28, TimeUnit.SECONDS);
        request.whenComplete((value, failure) -> main.post(() -> {
            timeout.cancel(false);
            unbind();
            if (pending == request) pending = null;
            JSONObject reply = response(value);
            if ("stopped".equals(reply.optString("status"))) lastStart = 0;
            if (!closed) result.accept(reply);
        }));
        try { Shizuku.bindUserService(args, connection); }
        catch (RuntimeException unavailable) { request.complete("unavailable"); }
    }
    private static JSONObject response(String value) {
        try {
            if (value != null && value.startsWith("{")) return new JSONObject(value);
            return new JSONObject().put("status", value == null ? "unavailable" : value);
        } catch (org.json.JSONException invalid) { throw new IllegalStateException(invalid); }
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
