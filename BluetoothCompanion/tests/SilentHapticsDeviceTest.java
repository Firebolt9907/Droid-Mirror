package app.droidmirror.bluetooth;

import android.os.*;
import java.lang.reflect.*;
import java.util.Objects;
import java.util.concurrent.atomic.AtomicInteger;

/** Run with no active mirror or trace. Uses production reader, suppression and recovery. */
public final class SilentHapticsDeviceTest {
    static void check(boolean value, String message) { if (!value) throw new AssertionError(message); }
    static String setting() throws Exception {
        String value = SilentHaptics.command("settings", "get", "system", "vibrate_on").trim();
        return value.equals("null") ? "absent" : value;
    }
    static Object service(String name, String type) throws Exception {
        IBinder binder = (IBinder) Class.forName("android.os.ServiceManager").getMethod("getService", String.class).invoke(null, name);
        return Class.forName(type + "$Stub").getMethod("asInterface", IBinder.class).invoke(null, binder);
    }
    static void requests() throws Exception {
        Class<?> api = Class.forName("android.os.IVibratorManagerService");
        Object manager = service("vibrator_manager", api.getName());
        for (int i=0; i<3; i++) {
            api.getMethod("vibrate", int.class, int.class, String.class, CombinedVibration.class, VibrationAttributes.class, String.class, IBinder.class)
                .invoke(manager, 2000, 0, "com.android.shell", CombinedVibration.createParallel(VibrationEffect.createPredefined(VibrationEffect.EFFECT_TICK)),
                    new VibrationAttributes.Builder().setUsage(VibrationAttributes.USAGE_COMMUNICATION_REQUEST).build(), "Silent haptic test", new Binder());
            Thread.sleep(100);
        }
        for (int i=0; i<3; i++) { feedback(); Thread.sleep(100); }
    }
    static void feedback() throws Exception {
        Class<?> api = Class.forName("android.os.IVibratorManagerService");
        Object manager = service("vibrator_manager", api.getName());
        Method feedback = null;
        for (Method method : api.getDeclaredMethods()) if (method.getName().equals("performHapticFeedback")) feedback = method;
        check(feedback != null, "UI feedback API unavailable");
        if (feedback.getParameterCount()==8) feedback.invoke(manager,2000,0,"com.android.shell",3,0,"Silent UI haptic test",0,0);
        else feedback.invoke(manager,2000,0,"com.android.shell",3,"Silent UI haptic test",0,0);
    }
    static void awaitRestored(String original) throws Exception {
        long deadline = SystemClock.elapsedRealtime()+8000;
        while (SystemClock.elapsedRealtime()<deadline) {
            if (Objects.equals(original, setting()) && SilentHaptics.command("cat", "/sys/kernel/tracing/tracing_on").trim().equals("0")) return;
            Thread.sleep(100);
        }
        throw new AssertionError("Vibration/trace lease not restored");
    }
    public static void main(String[] args) throws Exception {
        String original = setting();
        if (args.length>0 && args[0].equals("hold")) {
            try (SilentHaptics silent = new SilentHaptics(0, original, () -> {}, () -> true)) {
                System.out.println("SILENT_HAPTICS_READY"); System.out.flush();
                for (int i=0;i<150;i++) { silent.heartbeat(); Thread.sleep(100); }
            }
            return;
        }
        AtomicInteger ticks = new AtomicInteger(), motors = new AtomicInteger();
        try (HapticListener state = new HapticListener(motors::incrementAndGet);
             SilentHaptics silent = new SilentHaptics(0, original, ticks::incrementAndGet, () -> true)) {
            check(silent.healthy() && setting().equals("0"), "Silent reader not established");
            requests(); Thread.sleep(300);
            check(ticks.get()==6, "Expected six requests, got " + ticks);
            check(motors.get()==0, "Phone motor activated");
            silent.heartbeat();
            long takeover = SystemClock.elapsedRealtime();
            silent.requestRestore(); // Deliberately do not call close: slow teardown must not hold the mute.
            while (!Objects.equals(original, setting()) && SystemClock.elapsedRealtime()-takeover<1500) Thread.sleep(20);
            check(Objects.equals(original, setting()), "Early vibration restore waited for teardown");
            if (original.equals("absent") || Integer.parseInt(original)>0) {
                while (motors.get()==0 && SystemClock.elapsedRealtime()-takeover<1500) { feedback(); Thread.sleep(20); }
                check(motors.get()>0, "Keyboard-feedback motor did not resume promptly");
                System.out.println("Keyboard-feedback motor resumed before close in " + (SystemClock.elapsedRealtime()-takeover) + "ms");
            }
        }
        awaitRestored(original);
        // The exact production guardian must restore after an uncatchable parent death.
        ProcessBuilder childBuilder = new ProcessBuilder("/system/bin/app_process", "/system/bin", SilentHapticsDeviceTest.class.getName(), "hold").redirectErrorStream(true);
        childBuilder.environment().put("CLASSPATH", System.getProperty("java.class.path"));
        java.lang.Process child = childBuilder.start();
        try {
            java.io.BufferedReader output = new java.io.BufferedReader(new java.io.InputStreamReader(child.getInputStream()));
            long deadline = SystemClock.elapsedRealtime()+10000; boolean ready=false;
            while (child.isAlive() && SystemClock.elapsedRealtime()<deadline) {
                if (output.ready() && "SILENT_HAPTICS_READY".equals(output.readLine())) { ready=true; break; }
                Thread.sleep(20);
            }
            check(ready, "Child listener failed to start");
            child.destroyForcibly(); child.waitFor(); awaitRestored(original);
        } finally { if (child.isAlive()) child.destroyForcibly(); }
        try (SilentHaptics silent = new SilentHaptics(0, original, () -> {}, () -> true)) {
            SilentHaptics.command("atrace", "--async_stop");
            check(!silent.healthy(), "Trace termination not detected");
        }
        awaitRestored(original);
        System.out.println("PASS: six silent requests, no motor onsets, normal restore, SIGKILL restore and trace-failure restore");
    }
}
