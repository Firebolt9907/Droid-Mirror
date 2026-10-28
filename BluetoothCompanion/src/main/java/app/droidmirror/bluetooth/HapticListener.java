package app.droidmirror.bluetooth;

import android.os.Binder;
import android.os.IBinder;
import android.os.Parcel;
import android.os.RemoteException;
import java.lang.reflect.Method;
import java.util.ArrayList;
import java.util.List;

/** Shell-only hidden API adapter. Reports state onsets, not individual waveform pulses. */
final class HapticListener implements AutoCloseable {
    private static final String DESCRIPTOR = "android.os.IVibratorStateListener";
    private final List<Object[]> registrations = new ArrayList<>();
    private Object service;
    private Method unregister;
    private volatile boolean active = true;

    HapticListener(Runnable onset) throws Exception {
        try {
            IBinder binder = (IBinder) Class.forName("android.os.ServiceManager")
                .getMethod("getService", String.class).invoke(null, "vibrator_manager");
            Class<?> api = Class.forName("android.os.IVibratorManagerService");
            Class<?> listenerType = Class.forName(DESCRIPTOR);
            service = Class.forName("android.os.IVibratorManagerService$Stub")
                .getMethod("asInterface", IBinder.class).invoke(null, binder);
            Method register = api.getMethod("registerVibratorStateListener", int.class, listenerType);
            unregister = api.getMethod("unregisterVibratorStateListener", int.class, listenerType);
            int[] ids = (int[]) api.getMethod("getVibratorIds").invoke(service);
            for (int id : ids) {
                Binder callback = new Binder() {
                    private boolean known, vibrating;
                    @Override protected synchronized boolean onTransact(int code, Parcel data, Parcel reply, int flags)
                            throws RemoteException {
                        if (code != FIRST_CALL_TRANSACTION) return super.onTransact(code, data, reply, flags);
                        data.enforceInterface(DESCRIPTOR);
                        boolean next = data.readInt() != 0;
                        // Registration immediately reports the current state; it is not a new haptic.
                        boolean tick = known && !vibrating && next;
                        known = true; vibrating = next;
                        if (active && tick) onset.run();
                        return true;
                    }
                };
                Object listener = Class.forName(DESCRIPTOR + "$Stub")
                    .getMethod("asInterface", IBinder.class).invoke(null, callback);
                if (Boolean.TRUE.equals(register.invoke(service, id, listener))) {
                    registrations.add(new Object[]{id, listener});
                }
            }
            if (registrations.isEmpty()) throw new IllegalStateException("No vibrator listener registered");
            android.util.Log.i("DroidMirrorHaptics", "State listener active (display guard v76)");
        } catch (Exception failure) { close(); throw failure; }
    }

    @Override public void close() {
        active = false;
        for (Object[] registration : registrations) {
            try { unregister.invoke(service, registration); }
            catch (Exception failure) { android.util.Log.w("DroidMirrorHaptics", "Listener removal failed", failure); }
        }
        registrations.clear();
    }
}
