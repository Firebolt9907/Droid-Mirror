package com.genymobile.scrcpy;

import com.genymobile.scrcpy.device.Device;
import com.genymobile.scrcpy.util.Ln;
import com.genymobile.scrcpy.wrappers.ServiceManager;

import android.content.ComponentName;
import android.content.Intent;
import android.os.Binder;
import android.os.Bundle;
import android.os.Handler;
import android.os.IBinder;
import android.os.Looper;
import android.os.Parcel;
import android.os.RemoteException;
import android.os.SystemClock;

/** Phone-local recovery and a death-tracked companion notification for ADB streams. */
public final class AdbStreamSession implements AutoCloseable {
    public static final String DESCRIPTOR = "app.droidmirror.adb.Stream";
    public static final int ATTACH = IBinder.FIRST_CALL_TRANSACTION;
    public static final int DISCONNECT = ATTACH + 1;
    public static final int ENDED = ATTACH + 2;
    private final Handler main = new Handler(Looper.getMainLooper());
    private final CleanUp cleanUp;
    private boolean armed;
    private boolean localUse;
    private boolean closed;
    private boolean announced;
    private IBinder notification;
    private long lastActivity;
    private final Binder owner = new Binder() {
        @Override protected boolean onTransact(int code, Parcel data, Parcel reply, int flags) throws RemoteException {
            if (code != ATTACH && code != DISCONNECT) return super.onTransact(code, data, reply, flags);
            data.enforceInterface(DESCRIPTOR);
            if (code == ATTACH) {
                IBinder callback = data.readStrongBinder();
                main.post(() -> {
                    if (closed) signal(callback, ENDED);
                    else notification = callback;
                });
            } else main.post(() -> Looper.getMainLooper().quitSafely());
            return true;
        }
    };
    private final Runnable tick = new Runnable() {
        @Override public void run() {
            if (closed) return;
            boolean interactive = Device.isScreenOn(0);
            if (interactive) armed = true;
            if (armed && !interactive) {
                localUse = true;
                // Cleanup's separate process and the Mac must preserve this local wake.
                if (cleanUp != null) cleanUp.preserveLocalUse();
                Looper.getMainLooper().quitSafely();
                return;
            }
            if (interactive && SystemClock.elapsedRealtime() - lastActivity >= 1000) {
                lastActivity = SystemClock.elapsedRealtime();
                keepAwake();
            }
            main.postDelayed(this, 50);
        }
    };

    public AdbStreamSession(CleanUp cleanUp) {
        this.cleanUp = cleanUp;
        main.post(tick);
    }

    /** Called only after a video frame has been written to the connected Mac. */
    public void frameSent() {
        main.post(() -> {
            if (closed || announced) return;
            announced = true;
            Intent intent = new Intent().setComponent(new ComponentName("app.droidmirror.bluetooth",
                    "app.droidmirror.bluetooth.AdbStreamService"));
            Bundle extras = new Bundle();
            extras.putBinder("owner", owner);
            extras.putLong("startedElapsed", SystemClock.elapsedRealtime());
            intent.putExtras(extras);
            try {
                if (ServiceManager.getActivityManager().startForegroundService(intent) == null) {
                    Ln.w("Install the DroidMirror companion for the phone stream Live Activity");
                }
            } catch (ReflectiveOperationException | RuntimeException e) {
                Ln.w("Phone stream Live Activity unavailable", e);
            }
        });
    }

    public static void signal(IBinder target, int code) {
        if (target == null) return;
        Parcel data = Parcel.obtain();
        try {
            data.writeInterfaceToken(DESCRIPTOR);
            target.transact(code, data, null, IBinder.FLAG_ONEWAY);
        } catch (RemoteException ignored) {
            // Peer death also removes the notification.
        } finally { data.recycle(); }
    }

    private static Object service(String name, String type) throws ReflectiveOperationException {
        Object binder = Class.forName("android.os.ServiceManager").getMethod("getService", String.class).invoke(null, name);
        return Class.forName(type + "$Stub").getMethod("asInterface", IBinder.class).invoke(null, binder);
    }

    private static void keepAwake() {
        try {
            Object power = service("power", "android.os.IPowerManager");
            Class<?> type = Class.forName("android.os.IPowerManager");
            // NO_CHANGE_LIGHTS keeps the physical panel dark without changing timeout settings.
            try {
                type.getMethod("userActivity", int.class, long.class, int.class, int.class)
                    .invoke(power, 0, SystemClock.uptimeMillis(), 0, 1);
            } catch (NoSuchMethodException older) {
                type.getMethod("userActivity", long.class, int.class, int.class)
                    .invoke(power, SystemClock.uptimeMillis(), 0, 1);
            }
        } catch (ReflectiveOperationException e) { Ln.w("Could not keep ADB session awake", e); }
    }

    @Override public void close() {
        if (closed) return;
        closed = true;
        main.removeCallbacks(tick);
        signal(notification, ENDED);
        if (!localUse) return;
        // Capture and sockets have already stopped. Confirm keyguard before lighting the panel.
        try {
            Object window = service("window", "android.view.IWindowManager");
            Class<?> type = Class.forName("android.view.IWindowManager");
            type.getMethod("lockNow", Bundle.class).invoke(window, new Bundle());
            long deadline = SystemClock.elapsedRealtime() + 500;
            while (!(boolean) type.getMethod("isKeyguardLocked").invoke(window)) {
                if (SystemClock.elapsedRealtime() >= deadline) throw new IllegalStateException("Keyguard lock not confirmed");
                SystemClock.sleep(10);
            }
            if (!Device.setDisplayPower(0, true)) throw new IllegalStateException("Panel restoration failed");
            Object power = service("power", "android.os.IPowerManager");
            Class.forName("android.os.IPowerManager").getMethod("wakeUp", long.class, int.class, String.class, String.class)
                .invoke(power, SystemClock.uptimeMillis(), 2, "DroidMirror:local-use", "com.android.shell");
            deadline = SystemClock.elapsedRealtime() + 500;
            while (!Device.isScreenOn(0)) {
                if (SystemClock.elapsedRealtime() >= deadline) throw new IllegalStateException("Display wake not confirmed");
                SystemClock.sleep(10);
            }
            // Machine-readable marker also keeps the Mac's final cleanup from sending SLEEP.
            Ln.i("DROIDMIRROR_LOCAL_USE");
        } catch (ReflectiveOperationException | RuntimeException e) {
            Ln.e("Could not restore local lock screen", e);
        }
    }
}
