package app.droidmirror.bluetooth;

import android.content.ComponentName;
import android.content.Context;
import android.content.ServiceConnection;
import android.os.Handler;
import android.os.IBinder;
import android.os.Looper;
import org.json.JSONObject;
import java.util.concurrent.Executors;
import java.util.concurrent.ScheduledExecutorService;
import java.util.concurrent.TimeUnit;
import java.util.function.Consumer;
import rikka.shizuku.Shizuku;

/** Exists only while an authenticated Mac explicitly subscribes to clipboard sync. */
public final class ClipboardSyncClient implements AutoCloseable {
    private final Handler main = new Handler(Looper.getMainLooper());
    private final ScheduledExecutorService work = Executors.newSingleThreadScheduledExecutor();
    private final Consumer<JSONObject> events;
    private final Shizuku.UserServiceArgs args;
    private volatile IClipboardBridge remote;
    private volatile boolean closed;
    private boolean binding;
    private final ClipboardChangeTracker changes = new ClipboardChangeTracker();
    private String lastStatus;
    private final ServiceConnection connection = new ServiceConnection() {
        @Override public void onServiceConnected(ComponentName name, IBinder binder) {
            if (closed) { unbind(); return; }
            remote = IClipboardBridge.Stub.asInterface(binder);
        }
        @Override public void onServiceDisconnected(ComponentName name) { remote = null; binding = false; }
    };
    public ClipboardSyncClient(Context context, Consumer<JSONObject> events) {
        this.events = events;
        args = new Shizuku.UserServiceArgs(new ComponentName(context.getPackageName(), ClipboardBridgeService.class.getName()))
            .daemon(false).processNameSuffix("clipboard_bridge").debuggable(false).version(2);
        main.post(this::connect);
        work.scheduleWithFixedDelay(this::poll, 0, 750, TimeUnit.MILLISECONDS);
    }
    private void connect() {
        if (closed) return;
        if (!binding && ShizukuDisplayClient.authorized()) {
            binding = true;
            try { Shizuku.bindUserService(args, connection); }
            catch (RuntimeException failure) { binding = false; }
            main.postDelayed(() -> {
                if (!closed && remote == null) { unbind(); binding = false; }
            }, 10000);
        }
        main.postDelayed(this::connect, 5000);
    }
    private void emit(String type, String key, Object value) {
        try {
            JSONObject event = new JSONObject().put("type", type).put(key, value);
            main.post(() -> { if (!closed) events.accept(event); });
        } catch (org.json.JSONException ignored) {}
    }
    private void status(String status) {
        if (!status.equals(lastStatus)) { lastStatus = status; emit("clipboardStatus", "status", status); }
    }
    private void poll() {
        if (closed) return;
        IClipboardBridge service = remote;
        if (service == null || !ShizukuDisplayClient.authorized()) {
            changes.reset(); status("unavailable"); return;
        }
        try {
            String text = service.readText();
            // Rebaseline after lock or sensitive content.
            // Reconnecting never sends the phone's pre-existing clipboard.
            String availability = service.getStatus();
            if ("ready".equals(availability)) {
                if (changes.sample(text)) emit("clipboard", "text", text);
            } else changes.reset();
            status(availability);
        } catch (android.os.RemoteException | RuntimeException failure) {
            remote = null; changes.reset(); status("unavailable");
            main.post(() -> { unbind(); binding = false; });
        }
    }
    public void setText(String text) {
        if (closed || !ClipboardTextPolicy.allowed(text)) return;
        try { work.execute(() -> {
            if (closed) return;
            boolean success = false;
            try {
                IClipboardBridge service = remote;
                success = service != null && ShizukuDisplayClient.authorized() && service.writeText(text);
                if (success) changes.applied(text);
            } catch (android.os.RemoteException | RuntimeException ignored) {}
            emit("clipboardResult", "success", success);
        }); } catch (java.util.concurrent.RejectedExecutionException ignored) {}
    }
    private void unbind() {
        try { Shizuku.unbindUserService(args, connection, false); } catch (RuntimeException ignored) {}
    }
    @Override public void close() {
        closed = true; remote = null;
        main.removeCallbacksAndMessages(null);
        work.shutdownNow();
        main.post(this::unbind);
    }
}
