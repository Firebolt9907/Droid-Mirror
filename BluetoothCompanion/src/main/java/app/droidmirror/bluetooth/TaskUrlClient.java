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

/** Lives only for an authenticated Mac subscription. No URLs are stored or logged. */
public final class TaskUrlClient implements AutoCloseable {
    private final Handler main = new Handler(Looper.getMainLooper());
    private final ScheduledExecutorService work = Executors.newSingleThreadScheduledExecutor();
    private final Consumer<JSONObject> events;
    private final Shizuku.UserServiceArgs args;
    private volatile ITaskUrlBridge remote;
    private volatile boolean closed;
    private boolean binding;
    private final ServiceConnection connection = new ServiceConnection() {
        @Override public void onServiceConnected(ComponentName name, IBinder binder) {
            if (closed) { unbind(); return; }
            remote = ITaskUrlBridge.Stub.asInterface(binder);
        }
        @Override public void onServiceDisconnected(ComponentName name) { remote = null; binding = false; }
    };
    public TaskUrlClient(Context context, Consumer<JSONObject> events) {
        this.events = events;
        args = new Shizuku.UserServiceArgs(new ComponentName(context.getPackageName(), TaskUrlBridgeService.class.getName()))
                .daemon(false).processNameSuffix("task_urls").debuggable(false).version(3);
        main.post(this::connect);
        work.scheduleWithFixedDelay(this::poll, 0, 2, TimeUnit.SECONDS);
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
    private void poll() {
        if (closed) return;
        JSONObject event = new JSONObject();
        try {
            ITaskUrlBridge service = remote;
            String value = service != null && ShizukuDisplayClient.authorized() ? service.readTask() : "";
            if (value != null && !value.isEmpty()) event = new JSONObject(value);
        } catch (Exception failure) {
            remote = null;
            main.post(() -> { unbind(); binding = false; });
        }
        try {
            event.put("type", "taskContinuation");
            JSONObject snapshot = event;
            // Refresh even unchanged URLs so the Mac can expire interrupted connections.
            main.post(() -> { if (!closed) events.accept(snapshot); });
        } catch (org.json.JSONException ignored) {}
    }
    public void openBrowser(String url, java.util.function.BooleanSupplier authorized, Consumer<Boolean> reply) {
        if (closed) { reply.accept(false); return; }
        openBrowserAttempt(url, authorized, reply, 12);
    }
    private void openBrowserAttempt(String url, java.util.function.BooleanSupplier authorized, Consumer<Boolean> reply, int remaining) {
        work.schedule(() -> {
            if (!closed && remote == null && remaining > 0 && authorized.getAsBoolean() && ShizukuDisplayClient.authorized()) {
                openBrowserAttempt(url, authorized, reply, remaining - 1);
                return;
            }
            boolean success = false;
            try {
                ITaskUrlBridge service = remote;
                if (!closed && authorized.getAsBoolean() && ShizukuDisplayClient.authorized() && service != null
                        && TaskUrlResolver.webUrl(url)) success = service.openBrowser(url);
            } catch (Exception ignored) {}
            boolean result = success;
            main.post(() -> { if (!closed && authorized.getAsBoolean()) reply.accept(result); });
        }, 250, TimeUnit.MILLISECONDS);
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
