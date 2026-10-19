import android.content.ComponentName;
import android.content.Intent;
import android.os.*;
import com.genymobile.scrcpy.RemoteUseWarning;
import com.genymobile.scrcpy.wrappers.ServiceManager;

/** Shell-only device probe: simulate the monitor callback without injecting phone input. */
public final class RemoteUseWarningProbe {
    public static void main(String[] args) throws Exception {
        if (args.length > 0 && "launch".equals(args[0])) {
            if (!RemoteUseWarning.launch(args.length > 1 ? args[1] : null)) throw new IllegalStateException("Detached helper did not post warning");
            System.out.println("DETACHED_WARNING_POSTED");
            return;
        }
        Looper.prepare();
        Handler main = new Handler(Looper.myLooper());
        Binder monitor = new Binder() {
            @Override protected boolean onTransact(int code, Parcel data, Parcel reply, int flags) throws RemoteException {
                data.enforceInterface(RemoteUseWarning.DESCRIPTOR);
                if (code == RemoteUseWarning.DISMISS) {
                    System.out.println("DISMISSED " + SystemClock.elapsedRealtime());
                    main.getLooper().quitSafely();
                } else if (code == RemoteUseWarning.ATTACH) {
                    IBinder observer = data.readStrongBinder();
                    Runnable touch = () -> {
                        Parcel event = Parcel.obtain();
                        try {
                            event.writeInterfaceToken(RemoteUseWarning.DESCRIPTOR);
                            event.writeLong(SystemClock.elapsedRealtime());
                            System.out.println("TOUCH " + SystemClock.elapsedRealtime());
                            observer.transact(RemoteUseWarning.TOUCH, event, null, IBinder.FLAG_ONEWAY);
                        } catch (RemoteException failure) { throw new RuntimeException(failure); }
                        finally { event.recycle(); }
                    };
                    main.postDelayed(touch, 3000);
                    main.postDelayed(touch, 6000); // Must not extend the first touch's deadline.
                } else return false;
                return true;
            }
        };
        Bundle extras = new Bundle(); extras.putBinder("touchMonitor", monitor);
        if (args.length > 0) extras.putString("computerName", args[0]);
        Intent intent = new Intent().setComponent(new ComponentName("app.droidmirror.bluetooth",
            "app.droidmirror.bluetooth.RemoteUseWarningService")).putExtras(extras);
        ServiceManager.getActivityManager().startForegroundService(intent);
        main.postDelayed(() -> { System.out.println("TIMEOUT"); main.getLooper().quitSafely(); }, 20000);
        Looper.loop();
    }
}
