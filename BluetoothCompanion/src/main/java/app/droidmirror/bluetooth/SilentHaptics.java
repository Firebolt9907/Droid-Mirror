package app.droidmirror.bluetooth;

import android.os.SystemClock;
import android.system.ErrnoException;
import android.system.Os;
import android.system.OsConstants;
import android.system.StructPollfd;
import java.io.File;
import java.io.FileDescriptor;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.util.Objects;
import java.util.concurrent.TimeUnit;

/** Session-only request tracing. An independent shell process restores vibration on EOF/timeout. */
final class SilentHaptics implements AutoCloseable {
    private static final String TRACE = "/sys/kernel/tracing/";
    // This process owns only its saved setting and trace session. It survives an abrupt
    // display-guard death, and a missing heartbeat also releases a stalled guard's mute.
    static final String RECOVERY =
        "while IFS= read -r -t 5 command; do [ \"$command\" = stop ] && break; done\n"
        + "for attempt in 1 2 3; do\n"
        + " current=$(settings --user \"$1\" get system vibrate_on)\n"
        + " if [ \"$current\" != 0 ]; then\n"
        + "  [ \"$2\" = absent ] && [ \"$current\" = null ] && settings --user \"$1\" delete system vibrate_on\n"
        + "  break\n fi\n"
        + " if [ \"$2\" = absent ]; then settings --user \"$1\" delete system vibrate_on; "
        + "else settings --user \"$1\" put system vibrate_on \"$2\"; fi\n"
        + " current=$(settings --user \"$1\" get system vibrate_on)\n"
        + " [ \"$current\" = \"$2\" ] && break\n"
        + " [ \"$2\" = absent ] && [ \"$current\" = null ] && break\n"
        + " sleep 0.1\ndone\n"
        + "log -t DroidMirrorHaptics 'Phone vibration setting restored by watchdog'\n"
        + "if [ \"$(getprop debug.atrace.tags.enableflags)\" = \"$3\" ]; then atrace --async_stop >/dev/null; fi\n"
        + "log -t DroidMirrorHaptics 'Silent-haptic watchdog released vibration and trace lease'\n";
    private final int user;
    private final String original;
    private final Runnable onset;
    private FileDescriptor input;
    private Thread reader;
    private Process recovery;
    private String traceTags;
    private boolean ownsTrace;
    private boolean muteAttempted, restored;
    private volatile boolean running = true, enabled;
    private volatile Throwable failure;
    private long lastHeartbeat;
    private final Object recoveryControl = new Object();
    private boolean restorationRequested;

    SilentHaptics(int user, String original, Runnable onset, java.util.function.BooleanSupplier sessionAlive) throws Exception {
        this.user = user; this.original = original; this.onset = onset;
        if (user < 0 || !HapticVibrationLease.valid(original)) throw new IllegalArgumentException("Invalid vibration snapshot");
        try {
            if (!"0".equals(read(TRACE + "tracing_on"))) throw new IllegalStateException("System tracing already in use");
            String tags = property("debug.atrace.tags.enableflags");
            if (!tags.isEmpty() && !tags.equals("0")) throw new IllegalStateException("Trace categories already in use");
            input = Os.open(TRACE + "trace_pipe", OsConstants.O_RDONLY | OsConstants.O_NONBLOCK | OsConstants.O_CLOEXEC, 0);
            String pid = command("pidof", "system_server").trim();
            if (!pid.matches("[0-9]+")) throw new IllegalStateException("System server unavailable");
            HapticTraceParser parser = new HapticTraceParser(Integer.parseInt(pid));
            try { command("atrace", "--async_start", "-b", "128", "vibrator"); }
            finally {
                traceTags = property("debug.atrace.tags.enableflags");
                ownsTrace = !traceTags.isEmpty() && !traceTags.equals("0");
            }
            if (!"1".equals(read(TRACE + "tracing_on")) || traceTags.isEmpty() || traceTags.equals("0")
                    || !read(TRACE + "trace_clock").contains("[boot]"))
                throw new IllegalStateException("Haptic trace configuration unavailable");
            recovery = new ProcessBuilder("/system/bin/sh", "-c", RECOVERY, "haptic-recovery",
                Integer.toString(user), original, traceTags).redirectErrorStream(true)
                .redirectOutput(new File("/dev/null")).start();
            heartbeat();
            reader = new Thread(() -> listen(parser), "HapticRequestTrace");
            reader.setDaemon(true); reader.start();
            if (!healthy()) throw new IllegalStateException("Haptic trace reader unavailable");
            String current = setting();
            if (!Objects.equals(current, original)) throw new IllegalStateException("Vibration preference changed during startup");
            if (!sessionAlive.getAsBoolean()) throw new IllegalStateException("Haptic startup cancelled");
            muteAttempted = true;
            command("settings", "--user", Integer.toString(user), "put", "system", "vibrate_on", "0");
            if (!"0".equals(setting()) || !healthy()) throw new IllegalStateException("Silent haptics unavailable");
            enabled = true;
            android.util.Log.i("DroidMirrorHaptics", "Request tracing and phone suppression active (display guard v76)");
        } catch (Exception | LinkageError error) { close(); throw error; }
    }
    private void listen(HapticTraceParser parser) {
        StructPollfd poll = new StructPollfd(); poll.fd = input; poll.events = (short) OsConstants.POLLIN;
        byte[] bytes = new byte[4096];
        StringBuilder line = new StringBuilder();
        try {
            while (running) {
                if (Os.poll(new StructPollfd[]{poll}, 200) == 0) continue;
                if ((poll.revents & (OsConstants.POLLERR | OsConstants.POLLHUP | OsConstants.POLLNVAL)) != 0)
                    throw new IllegalStateException("Haptic trace stream ended");
                int count;
                try { count = Os.read(input, bytes, 0, bytes.length); }
                catch (ErrnoException empty) { if (empty.errno == OsConstants.EAGAIN) continue; throw empty; }
                if (count <= 0) throw new IllegalStateException("Haptic trace stream ended");
                for (int i = 0; i < count; i++) {
                    if (bytes[i] == '\n') {
                        boolean tick = parser.accept(line.toString(), SystemClock.elapsedRealtimeNanos() / 1e9);
                        line.setLength(0);
                        if (tick && enabled && running) onset.run();
                    } else {
                        if (line.length() >= 16384) throw new IllegalStateException("Invalid haptic trace record");
                        line.append((char) (bytes[i] & 255));
                    }
                }
            }
        } catch (Exception error) { if (running) failure = error; }
        finally { try { Os.close(poll.fd); } catch (Exception ignored) {} }
    }
    boolean healthy() {
        try {
            return running && failure == null && recovery != null && recovery.isAlive()
                && reader != null && reader.isAlive() && "1".equals(read(TRACE + "tracing_on"))
                && Objects.equals(traceTags, property("debug.atrace.tags.enableflags"));
        } catch (Exception error) { failure = error; return false; }
    }
    void heartbeat() throws Exception {
        synchronized (recoveryControl) {
        if (restorationRequested) return;
        if (recovery == null || !recovery.isAlive()) throw new IllegalStateException("Haptic recovery watchdog unavailable");
        if (SystemClock.elapsedRealtime() - lastHeartbeat < 1000) return;
        recovery.getOutputStream().write("alive\n".getBytes(StandardCharsets.US_ASCII));
        recovery.getOutputStream().flush(); lastHeartbeat = SystemClock.elapsedRealtime();
        }
    }
    private String setting() throws Exception {
        String value = command("settings", "--user", Integer.toString(user), "get", "system", "vibrate_on").trim();
        return value.equals("null") ? HapticVibrationLease.ABSENT : value;
    }
    private static String read(String path) throws Exception { return new String(Files.readAllBytes(new File(path).toPath()), StandardCharsets.UTF_8).trim(); }
    private static String property(String name) throws Exception {
        return (String) Class.forName("android.os.SystemProperties").getMethod("get", String.class).invoke(null, name);
    }
    static String command(String... args) throws Exception {
        Process process = new ProcessBuilder(args).redirectErrorStream(true).start();
        java.util.concurrent.FutureTask<byte[]> output = new java.util.concurrent.FutureTask<>(() -> {
            java.io.ByteArrayOutputStream saved = new java.io.ByteArrayOutputStream();
            byte[] buffer = new byte[4096]; int count;
            while ((count = process.getInputStream().read(buffer)) != -1) {
                if (saved.size() < 262144) saved.write(buffer, 0, Math.min(count, 262144 - saved.size()));
            }
            return saved.toByteArray();
        });
        Thread drain = new Thread(output, "HapticCommandOutput"); drain.setDaemon(true); drain.start();
        try {
            if (!process.waitFor(3, TimeUnit.SECONDS)) throw new IllegalStateException("Haptic command timed out");
            String result = new String(output.get(1, TimeUnit.SECONDS), StandardCharsets.UTF_8);
            if (process.exitValue() != 0) throw new IllegalStateException("Haptic command failed: " + args[0] + ": " + result);
            return result;
        } finally { if (process.isAlive()) process.destroyForcibly(); }
    }
    /** Nonblocking session-end phase: do not wait for reader, display, or trace cleanup. */
    void requestRestore() {
        enabled = false; running = false;
        synchronized (recoveryControl) {
            if (restorationRequested) return;
            restorationRequested = true;
            if (recovery != null) {
                try {
                    recovery.getOutputStream().write("stop\n".getBytes(StandardCharsets.US_ASCII));
                    recovery.getOutputStream().flush();
                    recovery.getOutputStream().close();
                } catch (Exception ignored) {}
            }
        }
    }
    @Override public void close() {
        long began = SystemClock.elapsedRealtime();
        requestRestore();
        // Restore before waiting on either process. The independent watchdog may
        // already have done this; it also covers parent death during this phase.
        try {
            if (muteAttempted && "0".equals(setting())) {
                if (HapticVibrationLease.ABSENT.equals(original)) command("settings", "--user", Integer.toString(user), "delete", "system", "vibrate_on");
                else command("settings", "--user", Integer.toString(user), "put", "system", "vibrate_on", original);
                if (!Objects.equals(setting(), original)) throw new IllegalStateException("Vibration restoration unconfirmed");
            }
            restored = true;
            android.util.Log.i("DroidMirrorHaptics", "Phone vibration setting restored in " + (SystemClock.elapsedRealtime() - began) + "ms");
        } catch (Exception error) { android.util.Log.e("DroidMirrorHaptics", "Vibration restoration pending", error); }
        // close runs outside the display-guard monitor, so a callback can finish.
        if (reader != null) {
            try { reader.join(500); } catch (InterruptedException interrupted) { Thread.currentThread().interrupt(); }
        }
        if (input != null && reader == null) {
            try { Os.close(input); } catch (Exception ignored) {} input = null;
        }
        if (recovery != null) {
            try { if (!recovery.waitFor(3, TimeUnit.SECONDS)) android.util.Log.w("DroidMirrorHaptics", "Vibration watchdog still restoring"); }
            catch (InterruptedException interrupted) { Thread.currentThread().interrupt(); }
            // Do not kill a watchdog that is still restoring the preference.
        }
        if (ownsTrace) {
            try {
                if (Objects.equals(traceTags, property("debug.atrace.tags.enableflags"))) command("atrace", "--async_stop");
                ownsTrace = false;
            }
            catch (Exception error) { android.util.Log.w("DroidMirrorHaptics", "Trace release pending", error); }
        }
    }
    boolean released() { return restored && !ownsTrace && (recovery == null || !recovery.isAlive()); }
}
