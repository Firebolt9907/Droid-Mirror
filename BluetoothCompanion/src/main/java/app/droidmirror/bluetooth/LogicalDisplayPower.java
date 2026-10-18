package app.droidmirror.bluetooth;

import android.annotation.SuppressLint;
import android.os.Bundle;
import android.os.SystemClock;
import java.lang.reflect.Method;

/** Runs only in the Shizuku shell/root service; never dismisses the keyguard. */
@SuppressLint({"PrivateApi", "SoonBlockedPrivateApi", "BlockedPrivateApi"})
final class LogicalDisplayPower {
    private Object power;
    private Object window;
    private Object service(String name, String type) throws Exception {
        Class<?> manager = Class.forName("android.os.ServiceManager");
        Object binder = manager.getMethod("getService", String.class).invoke(null, name);
        if (binder == null) throw new IllegalStateException("System service unavailable");
        return Class.forName(type + "$Stub").getMethod("asInterface", android.os.IBinder.class).invoke(null, binder);
    }
    boolean interactive() throws Exception {
        if (power == null) power = service("power", "android.os.IPowerManager");
        Class<?> type = Class.forName("android.os.IPowerManager");
        try { return (boolean)type.getMethod("isDisplayInteractive", int.class).invoke(power, 0); }
        catch (NoSuchMethodException older) { return (boolean)type.getMethod("isInteractive").invoke(power); }
    }
    boolean inUse() throws Exception {
        if (!interactive()) return false;
        if (window == null) window = service("window", "android.view.IWindowManager");
        return !(boolean)Class.forName("android.view.IWindowManager")
            .getMethod("isKeyguardLocked").invoke(window);
    }
    void keepAwake() throws Exception {
        if (power == null) power = service("power", "android.os.IPowerManager");
        Class<?> type = Class.forName("android.os.IPowerManager");
        // NO_CHANGE_LIGHTS preserves physical panel-off; no persistent timeout setting is changed.
        try { type.getMethod("userActivity", int.class, long.class, int.class, int.class)
            .invoke(power, 0, SystemClock.uptimeMillis(), 0, 1); }
        catch (NoSuchMethodException older) { type.getMethod("userActivity", long.class, int.class, int.class)
            .invoke(power, SystemClock.uptimeMillis(), 0, 1); }
    }
    void lock() throws Exception {
        if (window == null) window = service("window", "android.view.IWindowManager");
        Class.forName("android.view.IWindowManager").getMethod("lockNow", Bundle.class).invoke(window, new Bundle());
        Method locked = Class.forName("android.view.IWindowManager").getMethod("isKeyguardLocked");
        long deadline = SystemClock.elapsedRealtime() + 500;
        while (!(boolean)locked.invoke(window)) {
            if (SystemClock.elapsedRealtime() >= deadline) throw new IllegalStateException("Keyguard lock not confirmed");
            SystemClock.sleep(10);
        }
    }
    void sleep() throws Exception {
        if (power == null) power = service("power", "android.os.IPowerManager");
        Class.forName("android.os.IPowerManager").getMethod("goToSleep", long.class, int.class, int.class)
            .invoke(power, SystemClock.uptimeMillis(), 0, 0); // Allow normal doze/AOD policy.
        Class<?> global = Class.forName("android.hardware.display.DisplayManagerGlobal");
        Object manager = global.getMethod("getInstance").invoke(null);
        long deadline = SystemClock.elapsedRealtime() + 1500;
        while (true) {
            Object info = global.getMethod("getDisplayInfo", int.class).invoke(manager, 0);
            int state = info == null ? 0 : info.getClass().getField("state").getInt(info);
            if (!interactive() && (state == 1 || state == 3 || state == 4)) return;
            if (SystemClock.elapsedRealtime() >= deadline) throw new IllegalStateException("Display sleep not confirmed");
            SystemClock.sleep(10);
        }
    }
    void wake() throws Exception {
        if (power == null) power = service("power", "android.os.IPowerManager");
        Class.forName("android.os.IPowerManager").getMethod("wakeUp", long.class, int.class, String.class, String.class)
            .invoke(power, SystemClock.uptimeMillis(), 2, "DroidMirror:local-use", "com.android.shell");
        long deadline = SystemClock.elapsedRealtime() + 500;
        while (!interactive()) {
            if (SystemClock.elapsedRealtime() >= deadline) throw new IllegalStateException("Display wake not confirmed");
            SystemClock.sleep(10);
        }
    }
}
