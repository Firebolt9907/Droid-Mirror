package app.droidmirror.bluetooth;

import android.annotation.SuppressLint;
import android.content.Context;
import android.os.Binder;
import com.genymobile.scrcpy.FakeContext;
import java.lang.reflect.Proxy;
import java.util.concurrent.CompletableFuture;
import java.util.concurrent.Executor;
import java.util.concurrent.TimeUnit;

/** Shell-only Internet tethering. Leaves saved credentials and carrier checks intact. */
public final class HotspotBridgeService extends IHotspotBridge.Stub {
    public HotspotBridgeService() {}
    public HotspotBridgeService(Context context) {}

    @Override public String startHotspot() {
        long identity = Binder.clearCallingIdentity();
        try {
            if (android.os.Build.VERSION.SDK_INT < 30) return "unsupported";
            PrivilegedCapture.initialize();
            Class<?> api = Class.forName("android.net.TetheringManager");
            Object manager = FakeContext.get().getSystemService("tethering");
            if (manager == null) return "unsupported";
            // System-service caching otherwise retains the system Context's package,
            // which does not match Shizuku's shell UID for permission/app-op checks.
            // Intentional non-SDK access in the Shizuku shell process, never the
            // target-SDK app process. Missing/restricted OEM APIs fail below.
            @SuppressLint("BlockedPrivateApi")
            java.lang.reflect.Field context = api.getDeclaredField("mContext");
            context.setAccessible(true);
            context.set(manager, FakeContext.get());
            Class<?> builderType = Class.forName("android.net.TetheringManager$TetheringRequest$Builder");
            Object builder = builderType.getConstructor(int.class).newInstance(0); // TETHERING_WIFI
            builderType.getMethod("setShouldShowEntitlementUi", boolean.class).invoke(builder, false);
            Object request = builderType.getMethod("build").invoke(builder);
            Class<?> callbackType = Class.forName("android.net.TetheringManager$StartTetheringCallback");
            CompletableFuture<String> result = new CompletableFuture<>();
            Object callback = Proxy.newProxyInstance(callbackType.getClassLoader(), new Class<?>[]{callbackType},
                (proxy, method, args) -> {
                    switch (method.getName()) {
                        case "onTetheringStarted": result.complete("started"); return null;
                        case "onTetheringFailed": result.complete("failed:" + args[0]); return null;
                        case "hashCode": return System.identityHashCode(proxy);
                        case "equals": return proxy == args[0];
                        case "toString": return "DroidMirrorHotspotCallback";
                        default: return null;
                    }
                });
            api.getMethod("startTethering", request.getClass(), Executor.class, callbackType)
                .invoke(manager, request, (Executor) Runnable::run, callback);
            return result.get(20, TimeUnit.SECONDS);
        } catch (java.util.concurrent.TimeoutException timeout) {
            // The framework may still complete the request. Never retry automatically.
            return "timeout";
        } catch (Exception | LinkageError unavailable) {
            return "unavailable";
        } finally { Binder.restoreCallingIdentity(identity); }
    }
    @Override public void destroy() { System.exit(0); }
}
