package app.droidmirror.bluetooth;

import android.os.SystemClock;

/** Verify exclusive ownership and release using the exact production kernel-grab path. */
public final class TouchBlockRecoveryDeviceTest {
    public static void main(String[] args) throws Exception {
        if (args.length > 0 && "hold".equals(args[0])) {
            // Parent test kills this process to exercise kernel-owned restoration.
            TouchBlocker blocker = new TouchBlocker();
            if (!blocker.alive()) throw new AssertionError("Touch grab unavailable");
            System.out.println("TOUCH_BLOCKED"); System.out.flush();
            Thread.sleep(15000);
            blocker.close(); return;
        }
        try (TouchBlocker first = new TouchBlocker()) {
            boolean rejected = false;
            try (TouchBlocker duplicate = new TouchBlocker()) { /* must fail with EBUSY */ }
            catch (Exception busy) { rejected = true; }
            if (!rejected || !first.alive()) throw new AssertionError("Physical touch not exclusively owned");
            SystemClock.sleep(100);
        }
        try (TouchBlocker restored = new TouchBlocker()) {
            if (!restored.alive()) throw new AssertionError("Touch grab not released on close");
        }
        ProcessBuilder builder = new ProcessBuilder("/system/bin/app_process", "/", TouchBlockRecoveryDeviceTest.class.getName(), "hold")
            .redirectErrorStream(true);
        builder.environment().put("CLASSPATH", System.getProperty("java.class.path"));
        Process child = builder.start();
        try {
            java.io.BufferedReader lines = new java.io.BufferedReader(new java.io.InputStreamReader(child.getInputStream()));
            long deadline = SystemClock.elapsedRealtime() + 4000;
            boolean ready = false;
            while (child.isAlive() && SystemClock.elapsedRealtime() < deadline) {
                if (lines.ready() && "TOUCH_BLOCKED".equals(lines.readLine())) { ready = true; break; }
                Thread.sleep(10);
            }
            if (!ready) throw new AssertionError("Death-recovery grab did not start");
            child.destroyForcibly(); child.waitFor();
            try (TouchBlocker restored = new TouchBlocker()) {
                if (!restored.alive()) throw new AssertionError("Touch grab survived owner death");
            }
        } finally { child.destroyForcibly(); }
        System.out.println("TouchBlocker: exclusive touch grab, normal release and SIGKILL restoration passed");
    }
}
