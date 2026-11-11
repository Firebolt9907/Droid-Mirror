package app.droidmirror.bluetooth;

import android.content.Context;
import android.os.ParcelFileDescriptor;
import java.io.*;
import java.util.concurrent.*;

/** Independent, non-daemon shell service; no clipboard/display service replacement. */
public final class PackageInstallBridgeService extends IPackageInstallBridge.Stub {
    public PackageInstallBridgeService() {}
    public PackageInstallBridgeService(Context context) {}
    @Override public String install(ParcelFileDescriptor apk, long size) {
        if (!ApkInstallPolicy.allowed(size)) return "Invalid APK size";
        Process process = null;
        ExecutorService io = Executors.newFixedThreadPool(2);
        try (InputStream input = new ParcelFileDescriptor.AutoCloseInputStream(apk)) {
            process = new ProcessBuilder("cmd", "package", "install", "-r", "-S", Long.toString(size)).redirectErrorStream(true).start();
            final Process child = process;
            Future<?> writer = io.submit(() -> {
                try (OutputStream out = child.getOutputStream()) {
                    byte[] buffer = new byte[65536]; long remaining = size;
                    while (remaining > 0) {
                        int n = input.read(buffer, 0, (int)Math.min(buffer.length, remaining));
                        if (n < 0) throw new EOFException();
                        out.write(buffer, 0, n); remaining -= n;
                    }
                } catch (IOException failure) { throw new UncheckedIOException(failure); }
            });
            Future<String> reader = io.submit(() -> {
                ByteArrayOutputStream text = new ByteArrayOutputStream();
                try (InputStream output = child.getInputStream()) {
                    byte[] buffer = new byte[4096]; int n;
                    while ((n = output.read(buffer)) != -1) if (text.size() < 16384) text.write(buffer, 0, Math.min(n, 16384 - text.size()));
                }
                return text.toString("UTF-8");
            });
            long deadline = System.nanoTime() + TimeUnit.SECONDS.toNanos(120);
            writer.get(120, TimeUnit.SECONDS);
            if (!process.waitFor(Math.max(1, deadline - System.nanoTime()), TimeUnit.NANOSECONDS)) return "APK installation timed out";
            return reader.get(Math.max(1, deadline - System.nanoTime()), TimeUnit.NANOSECONDS);
        } catch (TimeoutException timeout) { return "APK installation timed out"; }
        catch (Exception failure) { return "APK installation failed: " + failure.getClass().getSimpleName(); }
        finally { if (process != null) process.destroyForcibly(); io.shutdownNow(); }
    }
}
