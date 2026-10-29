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

/** Bridge-scoped local support diagnostics; URL events require an authenticated subscription. */
public final class TaskUrlClient implements AutoCloseable {
    private final android.content.pm.PackageManager packageManager;
    private final Handler main = new Handler(Looper.getMainLooper());
    private final ScheduledExecutorService work = Executors.newSingleThreadScheduledExecutor();
    private final Consumer<JSONObject> events;
    private final Shizuku.UserServiceArgs args;
    private volatile ITaskUrlBridge remote;
    private volatile boolean closed;
    private volatile boolean subscribed;
    private volatile boolean changeOnly;
    private String lastTask = "";
    private long lastTaskGeneration = -1;
    private final Context context;
    private String lastDiagnostic = "";
    private long nextDiagnostic;
    private volatile long subscriptionGeneration;
    public void setSubscribed(boolean enabled, boolean changeOnly) { subscriptionGeneration++; this.changeOnly = changeOnly; subscribed = enabled; }

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
        this.context = context.getApplicationContext();
        this.packageManager = context.getApplicationContext().getPackageManager();
        args = new Shizuku.UserServiceArgs(new ComponentName(context.getPackageName(), TaskUrlBridgeService.class.getName()))
                .daemon(false).processNameSuffix("task_urls").debuggable(false).version(8);
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
        if (System.nanoTime() >= nextDiagnostic) {
            nextDiagnostic = System.nanoTime() + TimeUnit.SECONDS.toNanos(10);
            recordDiagnostics();
        }
        long generation = subscriptionGeneration;
        if (!subscribed) return;
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
            // Optional, bounded artwork. Failure must never suppress continuation.
            String packageName = event.optString("package", "");
            if (TaskUrlResolver.webUrl(event.optString("url", "")) && !packageName.isEmpty()) {
                String icon = appIcon(packageName);
                if (icon != null) event.put("appIcon", icon);
                if (event.toString().getBytes(java.nio.charset.StandardCharsets.UTF_8).length > 5200)
                    event.remove("appIcon");
            }
            if (changeOnly) event.put("changeOnly", true);
            JSONObject snapshot = event;
            String fingerprint = event.toString();
            // Change-only peers clear connection-scoped state on disconnect; legacy peers need leases.
            main.post(() -> {
                if (closed || !subscribed || generation != subscriptionGeneration) return;
                if (changeOnly && generation == lastTaskGeneration && fingerprint.equals(lastTask)) return;
                events.accept(snapshot);
                lastTask = fingerprint; lastTaskGeneration = generation;
            });
        } catch (org.json.JSONException ignored) {}
    }
    private void recordDiagnostics() {
        try {
            ITaskUrlBridge service = remote;
            String value = service != null && ShizukuDisplayClient.authorized()
                    ? service.readHandoffDiagnostics() : "{\"status\":\"shizuku_unavailable\"}";
            JSONObject record = new JSONObject(value);
            // Observe the same live URL path used by continuation, including offline.
            // Keep only package identity and success; the URL never enters the log.
            if (service != null && ShizukuDisplayClient.authorized()) {
                String task = service.readTask();
                if (task != null && !task.isEmpty()) {
                    JSONObject current = new JSONObject(task);
                    String pkg = current.optString("package", "");
                    if (TaskUrlResolver.webUrl(current.optString("url", ""))
                            && pkg.matches("[A-Za-z0-9_]+(?:\\.[A-Za-z0-9_]+)+"))
                        record.put("webContinuationPackage", pkg);
                }
            }
            value = record.toString();
            if (value.equals(lastDiagnostic)) return;
            record.put("time", System.currentTimeMillis());
            java.io.File file = new java.io.File(context.getFilesDir(), "handoff-support.jsonl");
            if (file.length() > 65536) {
                java.io.File previous = new java.io.File(context.getFilesDir(), "handoff-support.previous.jsonl");
                if (previous.exists() && !previous.delete()) return;
                if (!file.renameTo(previous)) return;
            }
            try (java.io.FileOutputStream out = new java.io.FileOutputStream(file, true)) {
                out.write((record.toString() + "\n").getBytes(java.nio.charset.StandardCharsets.UTF_8));
            }
            android.util.Log.i("DroidMirrorHandoff", record.toString());
            lastDiagnostic = value;
        } catch (Exception ignored) {}
    }
    private String appIcon(String packageName) {
        try {
            android.graphics.drawable.Drawable drawable = packageManager.getApplicationIcon(packageName);
            for (int size : new int[] {48, 32, 24, 16}) {
                android.graphics.Bitmap bitmap = android.graphics.Bitmap.createBitmap(size, size,
                        android.graphics.Bitmap.Config.ARGB_8888);
                java.io.ByteArrayOutputStream output = new java.io.ByteArrayOutputStream();
                try {
                    drawable.setBounds(0, 0, size, size);
                    drawable.draw(new android.graphics.Canvas(bitmap));
                    bitmap.compress(android.graphics.Bitmap.CompressFormat.PNG, 100, output);
                } finally { bitmap.recycle(); }
                byte[] bytes = output.toByteArray();
                if (bytes.length <= 2048)
                    return android.util.Base64.encodeToString(bytes, android.util.Base64.NO_WRAP);
            }
        } catch (Exception ignored) {}
        return null;
    }
    public void openBrowser(String url, java.util.function.BooleanSupplier authorized, Consumer<Boolean> reply) {
        if (closed) { reply.accept(false); return; }
        openBrowserAttempt(url, authorized, reply, 12);
    }
    /** No queue or retry: the listener has just checked session, version and unlock. */
    public boolean notificationReady() { return !closed && remote != null && ShizukuDisplayClient.authorized(); }
    public boolean openLauncher(String component) {
        ITaskUrlBridge service = remote;
        if (!notificationReady() || service == null) return false;
        try { return service.openLauncher(component); }
        catch (Exception unavailable) { return false; }
    }
    public boolean openNotification(android.app.PendingIntent intent) {
        ITaskUrlBridge service = remote;
        if (closed || service == null || !ShizukuDisplayClient.authorized()) return false;
        try { return service.openNotification(intent); }
        catch (Exception unavailable) {
            android.util.Log.w("DroidMirrorNotifications", "Notification bridge dispatch failed: " + unavailable.getClass().getSimpleName());
            return false;
        }
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
