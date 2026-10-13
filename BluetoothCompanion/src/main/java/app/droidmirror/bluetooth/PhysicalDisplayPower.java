package app.droidmirror.bluetooth;

import android.annotation.SuppressLint;
import android.os.Build;
import android.os.IBinder;
import android.os.Process;
import android.system.Os;
import java.lang.reflect.Method;
import java.util.ArrayList;
import java.util.List;

/** Physical-panel control adapted from scrcpy's Apache-2.0 SurfaceControl/DisplayControl wrappers. */
@SuppressLint({"PrivateApi", "SoonBlockedPrivateApi", "BlockedPrivateApi"})
final class PhysicalDisplayPower implements DisplayLease.Power {
    private Method setPower;
    private Class<?> controlApi;
    private final List<IBinder> tokens = new ArrayList<>();

    private void resolve() throws Exception {
        if (Process.myUid() != 2000 && Process.myUid() != 0) throw new SecurityException("Shell or root is required");
        Class<?> surface = Class.forName("android.view.SurfaceControl");
        setPower = surface.getMethod("setDisplayPowerMode", IBinder.class, int.class);
        List<IBinder> discovered = new ArrayList<>();
        boolean honorLegacy = Build.VERSION.SDK_INT == 34 && "honor".equalsIgnoreCase(Build.BRAND);
        if (Build.VERSION.SDK_INT < 29 || honorLegacy) {
            IBinder token;
            if (Build.VERSION.SDK_INT < 29) token = (IBinder)surface.getMethod("getBuiltInDisplay", int.class).invoke(null, 0);
            else token = (IBinder)surface.getMethod("getInternalDisplayToken").invoke(null);
            if (token == null) throw new IllegalStateException("No internal display token");
            discovered.add(token);
        } else {
            Class<?> control = controlApi == null ? surface : controlApi;
            try { control.getMethod("getPhysicalDisplayIds"); }
            catch (NoSuchMethodException moved) {
                Class<?> factory = Class.forName("com.android.internal.os.ClassLoaderFactory");
                Method create = factory.getDeclaredMethod("createClassLoader", String.class, String.class,
                    String.class, ClassLoader.class, int.class, boolean.class, String.class);
                String classpath = Os.getenv("SYSTEMSERVERCLASSPATH");
                if (classpath == null || classpath.isEmpty()) throw new IllegalStateException("System server classpath unavailable");
                ClassLoader loader = (ClassLoader)create.invoke(null, classpath, null, null,
                    ClassLoader.getSystemClassLoader(), 0, true, null);
                control = loader.loadClass("com.android.server.display.DisplayControl");
                Method load = Runtime.class.getDeclaredMethod("loadLibrary0", Class.class, String.class);
                load.setAccessible(true);
                load.invoke(Runtime.getRuntime(), control, "android_servers");
            }
            controlApi = control;
            long[] ids = (long[])control.getMethod("getPhysicalDisplayIds").invoke(null);
            if (ids == null || ids.length == 0) throw new IllegalStateException("No physical displays");
            Method getToken = control.getMethod("getPhysicalDisplayToken", long.class);
            for (long id : ids) {
                IBinder token = (IBinder)getToken.invoke(null, id);
                if (token == null) throw new IllegalStateException("Physical display token unavailable");
                discovered.add(token);
            }
        }
        tokens.clear(); tokens.addAll(discovered);
    }
    @Override public void set(boolean on) throws Exception {
        if (tokens.isEmpty()) {
            try { resolve(); }
            catch (LinkageError unsupported) { throw new IllegalStateException("Display API unavailable", unsupported); }
        }
        Exception failure = null;
        for (IBinder token : tokens) {
            try { setPower.invoke(null, token, on ? 2 : 0); }
            catch (Exception error) { failure = error; }
        }
        // Restore every cached display token even when one call fails.
        if (failure != null && on) {
            // A folded/unplugged display may retire its token. Resolve fresh tokens
            // without reloading the native library, then restore all current panels.
            resolve();
            failure = null;
            for (IBinder token : tokens) {
                try { setPower.invoke(null, token, 2); }
                catch (Exception error) { failure = error; }
            }
        }
        if (failure != null) throw failure;
    }
}
