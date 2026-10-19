package app.droidmirror.bluetooth;

import android.content.ComponentName;
import android.content.Context;
import android.content.ServiceConnection;
import android.os.Handler;
import android.os.IBinder;
import android.os.Looper;
import android.util.Log;
import org.json.JSONObject;
import rikka.shizuku.Shizuku;
import java.util.concurrent.Executors;
import java.util.concurrent.ScheduledExecutorService;
import java.util.concurrent.TimeUnit;
import java.util.function.Consumer;

/** Serialized clipboard state machine owned by BlePeripheral session. */
public final class ClipboardSyncClient implements AutoCloseable {
    private static final String TAG = "DroidMirrorClipboard";
    private final Handler main = new Handler(Looper.getMainLooper());
    private final ScheduledExecutorService work = Executors.newSingleThreadScheduledExecutor();
    private final Consumer<JSONObject> events;
    private final Shizuku.UserServiceArgs args;
    private final ClipboardFileTransfer files;
    private final boolean filesEnabled;
    private volatile IClipboardBridge remote;
    private volatile boolean closed;
    private boolean binding;
    private final ClipboardChangeTracker changes = new ClipboardChangeTracker();
    private String lastStatus = "";

    private final ServiceConnection connection = new ServiceConnection() {
        @Override public void onServiceConnected(ComponentName name, IBinder binder) {
            binding = false;
            if (closed) { unbind(); return; }
            Log.i(TAG, "Shizuku service connected: " + binder);
            remote = IClipboardBridge.Stub.asInterface(binder);
            try {
                binder.linkToDeath(() -> main.post(() -> {
                    Log.w(TAG, "Shizuku service died");
                    remote = null; status("unavailable");
                }), 0);
            } catch (android.os.RemoteException ignored) {}
        }
        @Override public void onServiceDisconnected(ComponentName name) {
            Log.w(TAG, "Shizuku service disconnected");
            remote = null; binding = false; status("unavailable");
        }
    };

    public ClipboardSyncClient(Context context, boolean filesEnabled, Consumer<JSONObject> events) {
        this.events = events;
        this.filesEnabled = filesEnabled;
        this.files = new ClipboardFileTransfer(context, event -> main.post(() -> { if (!closed) events.accept(event); }));
        this.args = new Shizuku.UserServiceArgs(new ComponentName(context.getPackageName(), ClipboardBridgeService.class.getName()))
            .daemon(false)
            .processNameSuffix("clipboard_bridge")
            .debuggable(false)
            .version(42);
        Log.i(TAG, "ClipboardSyncClient started, filesEnabled=" + filesEnabled);
        main.post(this::connect);
        work.scheduleWithFixedDelay(this::poll, 0, 750, TimeUnit.MILLISECONDS);
    }
    private void connect() {
        if (closed) return;
        if (!binding && remote == null && ShizukuDisplayClient.authorized()) {
            binding = true;
            try { Shizuku.bindUserService(args, connection); }
            catch (RuntimeException failure) {
                Log.w(TAG, "Shizuku.bindUserService failed", failure);
                binding = false;
            }
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
        try {
            IClipboardBridge service = remote;
            if (service == null || !ShizukuDisplayClient.authorized()) {
                files.reset(); changes.reset(); status("unavailable"); return;
            }
            String text = service.readText();
            // Rebaseline after lock or sensitive content.
            // Reconnecting never sends the phone's pre-existing clipboard.
            String availability = service.getStatus();
            if ("ready".equals(availability)) {
                if (filesEnabled) {
                    try { files.poll(service); } catch (Throwable failure) {
                        Log.w(TAG, "files.poll error", failure);
                        files.reset();
                    }
                }
                if (changes.sample(text)) emit("clipboard", "text", text);
            } else { files.reset(); changes.reset(); }
            status(availability);
        } catch (android.os.RemoteException | RuntimeException failure) {
            Log.w(TAG, "remote error during poll", failure);
            remote = null; files.reset(); changes.reset(); status("unavailable");
            main.post(() -> { unbind(); binding = false; });
        } catch (Throwable failure) {
            Log.e(TAG, "unexpected error during poll", failure);
        }
    }
    public void fileEvent(JSONObject event) {
        if (closed || !filesEnabled) return;
        try { work.execute(() -> {
            if (closed) return;
            try {
                if (remote != null && ShizukuDisplayClient.authorized()) files.receive(event, remote);
            } catch (Exception failure) {
                Log.w(TAG, "files.receive error", failure);
                files.reset();
            }
        }); } catch (java.util.concurrent.RejectedExecutionException ignored) {}
    }
    public void setText(String text) {
        if (closed || !ClipboardTextPolicy.allowed(text)) return;
        try { work.execute(() -> {
            if (closed) return;
            boolean success = false;
            try {
                IClipboardBridge service = remote;
                success = service != null && ShizukuDisplayClient.authorized() && service.writeText(text);
                if (success) {
                    changes.applied(text);
                    if (filesEnabled) files.textApplied(service);
                } else {
                    files.reset();
                }
            } catch (android.os.RemoteException | RuntimeException ignored) {
                files.reset();
            }
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
