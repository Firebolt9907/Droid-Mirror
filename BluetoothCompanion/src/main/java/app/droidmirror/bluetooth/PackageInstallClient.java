package app.droidmirror.bluetooth;

import android.content.*;
import android.os.*;
import java.io.File;
import java.util.concurrent.*;
import rikka.shizuku.Shizuku;

public final class PackageInstallClient {
    public static boolean available() { return Build.VERSION.SDK_INT >= 29 && ShizukuDisplayClient.authorized(); }
    // Called only on the file worker. Binding remains on Android's main thread.
    static String install(Context context, File file, long size, java.util.function.BooleanSupplier cancelled) {
        if (!available()) return "Make sure Shizuku is running and permission is granted";
        Handler main = new Handler(Looper.getMainLooper());
        CompletableFuture<IBinder> bound = new CompletableFuture<>();
        java.util.concurrent.atomic.AtomicBoolean closed = new java.util.concurrent.atomic.AtomicBoolean();
        Shizuku.UserServiceArgs args = new Shizuku.UserServiceArgs(new ComponentName(context.getPackageName(), PackageInstallBridgeService.class.getName()))
            .daemon(false).processNameSuffix("package_install").debuggable(false).version(1);
        ServiceConnection connection = new ServiceConnection() {
            public void onServiceConnected(ComponentName name, IBinder binder) { bound.complete(binder); }
            public void onServiceDisconnected(ComponentName name) { bound.completeExceptionally(new IllegalStateException("Installer disconnected")); }
        };
        main.post(() -> { if (!closed.get()) try { Shizuku.bindUserService(args, connection); } catch (RuntimeException error) { bound.completeExceptionally(error); } });
        ExecutorService call = Executors.newSingleThreadExecutor();
        try (ParcelFileDescriptor descriptor = ParcelFileDescriptor.open(file, ParcelFileDescriptor.MODE_READ_ONLY)) {
            IBinder binder = bound.get(10, TimeUnit.SECONDS);
            if (cancelled.getAsBoolean()) return "APK installation cancelled";
            Future<String> result = call.submit(() -> IPackageInstallBridge.Stub.asInterface(binder).install(descriptor, size));
            long deadline = System.nanoTime() + TimeUnit.SECONDS.toNanos(125);
            while (!cancelled.getAsBoolean() && System.nanoTime() < deadline) {
                try { return result.get(250, TimeUnit.MILLISECONDS); } catch (TimeoutException waiting) {}
            }
            return "APK installation cancelled or timed out";
        } catch (Exception failure) { return "APK installer unavailable or timed out"; }
        finally {
            closed.set(true); call.shutdownNow();
            main.post(() -> { try { Shizuku.unbindUserService(args, connection, true); } catch (RuntimeException ignored) {} });
        }
    }
    static String packageName(Context context, File file) {
        android.content.pm.PackageInfo info = context.getPackageManager().getPackageArchiveInfo(file.getAbsolutePath(), 0);
        return info == null ? null : info.packageName;
    }
}
