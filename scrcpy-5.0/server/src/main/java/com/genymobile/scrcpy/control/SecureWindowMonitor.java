package com.genymobile.scrcpy.control;

import java.io.InputStreamReader;
import java.nio.charset.StandardCharsets;
import java.util.concurrent.Executors;
import java.util.concurrent.ScheduledExecutorService;
import java.util.concurrent.ScheduledFuture;
import java.util.concurrent.TimeUnit;
import java.util.concurrent.atomic.AtomicBoolean;
import java.util.function.IntSupplier;
import java.util.function.BiConsumer;

/** Runs as shell under either Shizuku or ADB, independently of display recovery. */
final class SecureWindowMonitor {
    private final BiConsumer<Integer, Integer> result;
    private final IntSupplier queryOverride;
    private final IntSupplier displayId;
    private final ScheduledExecutorService deadlines = Executors.newSingleThreadScheduledExecutor();
    private final Thread thread;
    private volatile boolean stopped;
    private Process command;
    private boolean candidate;
    private int generation;

    SecureWindowMonitor(IntSupplier displayId, BiConsumer<Integer, Integer> result) {
        this(displayId, result, null);
    }

    SecureWindowMonitor(IntSupplier displayId, BiConsumer<Integer, Integer> result, IntSupplier queryOverride) {
        this.result = result;
        this.queryOverride = queryOverride;
        this.displayId = displayId;
        thread = new Thread(this::loop, "secure-window-monitor");
    }

    void start() { thread.start(); }

    synchronized void setCandidate(boolean black, int epoch) {
        if (stopped || (candidate == black && generation == epoch)) return;
        candidate = black;
        generation = epoch;
        if (command != null) command.destroyForcibly();
        notifyAll();
    }

    private int query() {
        Process process = null;
        ScheduledFuture<?> deadline = null;
        AtomicBoolean expired = new AtomicBoolean();
        try {
            int target = displayId.getAsInt();
            if (target < 0) return SecureWindowState.UNKNOWN;
            synchronized (this) {
                if (stopped || !candidate) return SecureWindowState.UNKNOWN;
                process = new ProcessBuilder("/system/bin/dumpsys", "-t", "1", "window", "windows")
                    .redirectErrorStream(true).start();
                command = process;
            }
            Process running = process;
            deadline = deadlines.schedule(() -> {
                expired.set(true);
                running.destroyForcibly();
            }, 1500, TimeUnit.MILLISECONDS);
            int state;
            try (InputStreamReader reader = new InputStreamReader(process.getInputStream(), StandardCharsets.UTF_8)) {
                state = SecureWindowState.read(reader, target);
            }
            // Reject timeout/partial output and a display switch during the query.
            if (!process.waitFor(100, TimeUnit.MILLISECONDS) || process.exitValue() != 0 || expired.get()
                    || target != displayId.getAsInt()) return SecureWindowState.UNKNOWN;
            return state;
        } catch (Exception failure) {
            return SecureWindowState.UNKNOWN;
        } finally {
            if (deadline != null) deadline.cancel(false);
            if (process != null) process.destroyForcibly();
            synchronized (this) { command = null; }
        }
    }

    private void loop() {
        try {
            while (true) {
                int epoch;
                synchronized (this) {
                    while (!stopped && !candidate) wait();
                    if (stopped) break;
                    epoch = generation;
                }
                int state = queryOverride != null ? queryOverride.getAsInt() : query();
                synchronized (this) {
                    if (stopped) break;
                    if (!candidate || generation != epoch) continue;
                    // Refresh only while black, including static screens with no new video frames.
                    result.accept(state, epoch);
                    wait(500);
                }
            }
        } catch (InterruptedException ignored) {
            Thread.currentThread().interrupt();
        } finally {
            deadlines.shutdownNow();
        }
    }

    synchronized void stop() {
        stopped = true;
        notifyAll();
        thread.interrupt();
        if (command != null) command.destroyForcibly();
        deadlines.shutdownNow();
    }
}
