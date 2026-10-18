package app.droidmirror.bluetooth;

import android.Manifest;
import android.content.ComponentName;
import android.content.Context;
import android.content.ServiceConnection;
import android.content.pm.PackageManager;
import android.os.Handler;
import android.os.IBinder;
import android.os.Looper;
import java.util.concurrent.CompletableFuture;
import java.util.concurrent.Executors;
import java.util.concurrent.ScheduledExecutorService;
import java.util.concurrent.TimeUnit;
import java.util.function.Consumer;
import rikka.shizuku.Shizuku;

/** Grants only DroidMirror's development permission through the existing shell service. */
public final class SecureSettingsPermission {
    private static final Handler MAIN = new Handler(Looper.getMainLooper());
    private static final ScheduledExecutorService WORK = Executors.newScheduledThreadPool(2);
    private static CompletableFuture<Boolean> pending;
    private SecureSettingsPermission() {}

    public static boolean granted(Context context) {
        return context.checkSelfPermission(Manifest.permission.WRITE_SECURE_SETTINGS) == PackageManager.PERMISSION_GRANTED;
    }
    public static boolean shizukuAuthorized() { return ShizukuDisplayClient.authorized(); }

    public static synchronized void ensure(Context context, Consumer<String> result) {
        Context app = context.getApplicationContext();
        if (granted(app)) { MAIN.post(() -> result.accept("Secure settings authorized.")); return; }
        if (!shizukuAuthorized()) {
            MAIN.post(() -> result.accept("Start and authorize Shizuku in the main setup screen to grant secure settings automatically."));
            return;
        }
        if (pending == null) pending = begin(app);
        pending.thenAccept(success -> MAIN.post(() -> result.accept(success
            ? "Secure settings granted with Shizuku."
            : "Shizuku could not grant secure settings. Check that it is running and retry.")));
    }

    private static CompletableFuture<Boolean> begin(Context context) {
        CompletableFuture<Boolean> request = new CompletableFuture<>();
        Shizuku.UserServiceArgs args = ShizukuDisplayClient.arguments(context);
        ServiceConnection connection = new ServiceConnection() {
            @Override public void onServiceConnected(ComponentName name, IBinder binder) {
                if (request.isDone()) { unbind(); return; }
                WORK.execute(() -> {
                    boolean success = false;
                    try {
                        success = IDisplayGuard.Stub.asInterface(binder).grantSecureSettings() && granted(context);
                    } catch (android.os.RemoteException | RuntimeException ignored) {}
                    request.complete(success);
                });
            }
            @Override public void onServiceDisconnected(ComponentName name) { request.complete(false); }
            private void unbind() {
                try { Shizuku.unbindUserService(args, this, false); } catch (RuntimeException ignored) {}
            }
        };
        var timeout = WORK.schedule(() -> request.complete(false), 12, TimeUnit.SECONDS);
        request.whenComplete((success, error) -> {
            timeout.cancel(false);
            synchronized (SecureSettingsPermission.class) { if (pending == request) pending = null; }
            MAIN.post(() -> { try { Shizuku.unbindUserService(args, connection, false); } catch (RuntimeException ignored) {} });
        });
        MAIN.post(() -> {
            if (request.isDone()) return;
            try { Shizuku.bindUserService(args, connection); }
            catch (RuntimeException unavailable) { request.complete(false); }
        });
        return request;
    }
}
