package app.droidmirror.bluetooth;

import android.system.Os;
import android.system.OsConstants;
import java.io.FileDescriptor;
import java.io.BufferedReader;
import java.io.InputStreamReader;
import java.util.ArrayList;
import java.util.List;
import java.util.concurrent.CompletableFuture;
import java.util.concurrent.TimeUnit;

/** Kernel-owned exclusive grabs release on close or process death, without global input changes. */
final class TouchBlocker implements AutoCloseable {
    // Linux _IOW('E', 0x90, int), fixed on every supported Android ABI.
    private static final int EVIOCGRAB = 0x40044590;
    private final List<FileDescriptor> grabbed = new ArrayList<>();
    TouchBlocker() throws Exception {
        Process query = new ProcessBuilder("/system/bin/getevent", "-lp").redirectErrorStream(true).start();
        try {
            CompletableFuture<String> output = CompletableFuture.supplyAsync(() -> {
                try {
                    StringBuilder text = new StringBuilder();
                    BufferedReader lines = new BufferedReader(new InputStreamReader(query.getInputStream()));
                    String line;
                    while ((line = lines.readLine()) != null) text.append(line).append('\n');
                    return text.toString();
                } catch (java.io.IOException failure) { throw new java.util.concurrent.CompletionException(failure); }
            });
            List<String> paths = TouchDevicePaths.select(output.get(2, TimeUnit.SECONDS));
            if (paths.isEmpty()) throw new IllegalStateException("No accessible physical touchscreen");
            for (String path : paths) {
                FileDescriptor fd = Os.open(path, OsConstants.O_RDONLY | OsConstants.O_CLOEXEC | OsConstants.O_NONBLOCK, 0);
                grabbed.add(fd); // Own rollback before attempting the grab.
                grab(fd);
            }
        } catch (Exception failure) { close(); throw failure; }
        finally { query.destroy(); }
    }
    private static void grab(FileDescriptor fd) throws Exception {
        // EVIOCGRAB treats the ioctl argument as a boolean value and never
        // dereferences it. ioctlInt supplies a non-null int pointer, i.e. true.
        // Closing the fd releases the grab; no ioctl with a null argument is needed.
        try {
            Os.class.getMethod("ioctlInt", FileDescriptor.class, int.class).invoke(null, fd, EVIOCGRAB);
        } catch (NoSuchMethodException older) {
            Class<?> ref = Class.forName("android.system.Int32Ref");
            Os.class.getMethod("ioctlInt", FileDescriptor.class, int.class, ref)
                .invoke(null, fd, EVIOCGRAB, ref.getConstructor(int.class).newInstance(0));
        }
    }
    boolean alive() {
        for (FileDescriptor fd : grabbed) if (!fd.valid()) return false;
        return !grabbed.isEmpty();
    }
    @Override public void close() {
        for (FileDescriptor fd : grabbed) {
            try { Os.close(fd); }
            catch (android.system.ErrnoException failure) { android.util.Log.e("DroidMirrorTouch", "Touch grab close failed", failure); }
        }
        grabbed.clear();
    }
}
