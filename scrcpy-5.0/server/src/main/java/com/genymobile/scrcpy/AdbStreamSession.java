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
    public static final int PREPARE_UNLOCK = ATTACH + 3;
    public static final int VERIFY_CALLER = ATTACH + 4;
    private final com.genymobile.scrcpy.video.VideoStartGate videoGate = new com.genymobile.scrcpy.video.VideoStartGate();
    public com.genymobile.scrcpy.video.VideoStartGate videoStartGate() { return videoGate; }
    private volatile boolean preparationSucceeded;
    private final java.util.concurrent.atomic.AtomicBoolean unlockRequested = new java.util.concurrent.atomic.AtomicBoolean();
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
            if (code != ATTACH && code != DISCONNECT && code != PREPARE_UNLOCK && code != VERIFY_CALLER) return super.onTransact(code, data, reply, flags);
            data.enforceInterface(DESCRIPTOR);
            if (code == VERIFY_CALLER) {
                IBinder verifier = data.readStrongBinder();
                byte[] nonce = data.createByteArray();
                if (verifier == null) throw new IllegalArgumentException("Verifier binder required");
                Parcel req = Parcel.obtain();
                Parcel rep = Parcel.obtain();
                try {
                    req.writeInterfaceToken(DESCRIPTOR);
                    req.writeByteArray(nonce);
                    verifier.transact(1, req, rep, 0);
                    rep.readException();
                } finally {
                    req.recycle();
                    rep.recycle();
                }
                if (reply != null) reply.writeNoException();
                return true;
            }
            if (code == PREPARE_UNLOCK) {
                byte[] pin = data.createByteArray();
                boolean success = false;
                try {
                    if (!unlockRequested.compareAndSet(false, true)) throw new IllegalStateException("Unlock already attempted");
                    if (pin != null) unlock(pin);
                    success = true;
                } catch (Exception error) { Ln.w("Automatic unlock failed; check the saved PIN in the Android app"); }
                finally { if (pin != null) java.util.Arrays.fill(pin, (byte) 0); }
                if (reply != null) { reply.writeNoException(); reply.writeInt(success ? 1 : 0); }
                return true;
            }
            if (code == ATTACH) {
                IBinder callback = data.readStrongBinder();
                preparationSucceeded = true; videoGate.open(System.nanoTime() / 1000);
                main.post(() -> {
                    if (closed) signal(callback, ENDED);
                    else notification = callback;
                });
            } else { main.post(() -> Looper.getMainLooper().quitSafely()); }
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

    public AdbStreamSession(CleanUp cleanUp) throws java.io.IOException {
        this.cleanUp = cleanUp;
        // The app returns the PIN only over phone-local Binder. Nothing travels on
        // the Mac control channel, command line, environment or video stream.
        if (announce(true)) {
            // Configure the encoder/decoder while the app prepares credentials.
            // Only codec metadata can pass until the successful ATTACH callback.
            main.postDelayed(() -> {
                if (!closed && !preparationSucceeded) {
                    Ln.w("Automatic unlock preparation timed out; check the Android app");
                    Looper.getMainLooper().quitSafely();
                }
            }, 8000);
        } else videoGate.open(System.nanoTime() / 1000);
        main.post(tick);
    }

    /** Called only after a video frame has been written to the connected Mac. */
    public void frameSent() {
        main.post(() -> {
            if (closed || announced) return;
            announced = true;
            announce(false);
        });
    }

    private boolean announce(boolean prepareUnlock) {
        Intent intent = new Intent().setComponent(new ComponentName("app.droidmirror.bluetooth",
                "app.droidmirror.bluetooth.AdbStreamService"));
        Bundle extras = new Bundle();
        extras.putBinder("owner", owner);
        extras.putLong("startedElapsed", SystemClock.elapsedRealtime());
        extras.putBoolean("prepareUnlock", prepareUnlock);
        intent.putExtras(extras);
        try {
            boolean started = ServiceManager.getActivityManager().startForegroundService(intent) != null;
            if (started) announced = true;
            return started;
        } catch (ReflectiveOperationException | RuntimeException error) {
            Ln.w("Phone stream Live Activity unavailable", error); return false;
        }
    }

    private static void unlock(byte[] pin) throws Exception {
        if (!com.genymobile.scrcpy.control.PinUnlock.valid(pin)) throw new IllegalArgumentException("Invalid PIN");
        Object window = service("window", "android.view.IWindowManager");
        java.lang.reflect.Method locked = Class.forName("android.view.IWindowManager").getMethod("isKeyguardLocked");
        if (!(boolean) locked.invoke(window)) return;
        if (!Device.isScreenOn(0)) {
            Device.pressReleaseKeycode(android.view.KeyEvent.KEYCODE_WAKEUP, 0, Device.INJECT_MODE_WAIT_FOR_FINISH);
            SystemClock.sleep(150);
        }
        com.genymobile.scrcpy.control.PinUnlock.unlock(pin, new com.genymobile.scrcpy.control.PinUnlock.Device() {
            public boolean locked() throws Exception { return (boolean) locked.invoke(window); }
            public void key(int keycode) throws Exception {
                if (!Device.pressReleaseKeycode(keycode, 0, Device.INJECT_MODE_WAIT_FOR_FINISH))\n                    throw new IllegalStateException("Unlock input unavailable");
            }
            public void sleep(long millis) { SystemClock.sleep(millis); }
            public long now() { return SystemClock.elapsedRealtime(); }
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
