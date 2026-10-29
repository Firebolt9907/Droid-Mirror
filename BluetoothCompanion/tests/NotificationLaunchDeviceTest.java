import android.app.PendingIntent;
import android.content.Context;
import android.content.Intent;
import java.lang.reflect.Method;

/** Run as shell with the companion APK on CLASSPATH; opens Developer options. */
public final class NotificationLaunchDeviceTest {
    public static void main(String[] args) throws Exception {
        android.os.Looper.prepareMainLooper();
        Object bridge = Class.forName("app.droidmirror.bluetooth.TaskUrlBridgeService").getConstructor().newInstance();
        Method open = bridge.getClass().getMethod("openNotification", PendingIntent.class);
        // First context initialization must happen on a fresh thread, like a
        // Shizuku Binder call, rather than being masked by main-thread setup.
        if (send(bridge, open, null)) throw new AssertionError("Null capability accepted");
        Context shell = (Context) Class.forName("com.genymobile.scrcpy.FakeContext").getMethod("get").invoke(null);
        Intent destination = new Intent(android.provider.Settings.ACTION_APPLICATION_DEVELOPMENT_SETTINGS)
            .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK);
        PendingIntent cancelled = PendingIntent.getActivity(shell, 73101, destination, PendingIntent.FLAG_IMMUTABLE);
        cancelled.cancel();
        if (send(bridge, open, cancelled)) throw new AssertionError("Cancelled capability accepted");
        PendingIntent valid = PendingIntent.getActivity(shell, 73102, destination, PendingIntent.FLAG_IMMUTABLE);
        try {
            Method locked = bridge.getClass().getDeclaredMethod("keyguardLocked");
            locked.setAccessible(true);
            if ((Boolean) locked.invoke(null)) {
                if (send(bridge, open, valid)) throw new AssertionError("Locked phone accepted open");
                System.out.println("PASS: locked phone and null/cancelled capabilities rejected; rerun unlocked to verify launch");
                return;
            }
            if (!send(bridge, open, valid)) throw new AssertionError("Developer options launch failed (phone must be unlocked)");
        } finally { valid.cancel(); }
        System.out.println("PASS: null/cancelled capabilities rejected; Developer options launch sent through shell bridge");
    }
    private static boolean send(Object bridge, Method open, PendingIntent intent) throws Exception {
        java.util.concurrent.FutureTask<Boolean> call = new java.util.concurrent.FutureTask<>(() -> {
            if (android.os.Looper.myLooper() != null) throw new AssertionError("Test thread already has a Looper");
            return (Boolean) open.invoke(bridge, new Object[]{intent});
        });
        new Thread(call, "notification-binder-test").start();
        return call.get(10, java.util.concurrent.TimeUnit.SECONDS);
    }
}
