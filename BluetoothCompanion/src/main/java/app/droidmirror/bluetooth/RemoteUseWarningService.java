package app.droidmirror.bluetooth;

import android.app.Notification;
import android.app.NotificationChannel;
import android.app.NotificationManager;
import android.app.PendingIntent;
import android.app.Service;
import android.content.BroadcastReceiver;
import android.content.Context;
import android.content.Intent;
import android.content.IntentFilter;
import android.content.pm.ServiceInfo;
import android.os.*;
import com.genymobile.scrcpy.RemoteUseWarning;

/** Holds the end-of-session warning until five seconds after the first local touch. */
public final class RemoteUseWarningService extends Service {
    private static final int NOTIFICATION = 2;
    private static final String TOUCHED = "app.droidmirror.bluetooth.action.ACK_REMOTE_USE";
    private static final String DISMISSED = "app.droidmirror.bluetooth.action.DISMISS_REMOTE_USE";
    private final Handler main = new Handler(Looper.getMainLooper());
    private IBinder monitor;
    private long touched;
    private String generation;
    private String computerName;
    private final Runnable localUseCheck = new Runnable() {
        @Override public void run() {
            if (touched != 0 || generation == null) return;
            // USER_PRESENT can arrive before this service starts (or before its
            // receiver registers). Reconcile the current state as well as events.
            android.app.KeyguardManager keyguard = getSystemService(android.app.KeyguardManager.class);
            PowerManager power = getSystemService(PowerManager.class);
            if (power.isInteractive() && !keyguard.isKeyguardLocked()) {
                firstTouch(SystemClock.elapsedRealtime());
            } else main.postDelayed(this, 250);
        }
    };
    private final BroadcastReceiver unlocked = new BroadcastReceiver() {
        @Override public void onReceive(Context context, Intent intent) { firstTouch(SystemClock.elapsedRealtime()); }
    };

    @Override public IBinder onBind(Intent intent) { return null; }
    @Override public void onCreate() {
        super.onCreate();
        // Fallback on devices without shell touch monitoring; screen-on alone never clears the warning.
        IntentFilter filter = new IntentFilter(Intent.ACTION_USER_PRESENT);
        if (Build.VERSION.SDK_INT >= 33) registerReceiver(unlocked, filter, Context.RECEIVER_NOT_EXPORTED);
        else registerReceiver(unlocked, filter);
    }
    @Override public int onStartCommand(Intent intent, int flags, int startId) {
        if (intent == null) { stopSelf(); return START_NOT_STICKY; }
        String action = intent.getAction();
        if (TOUCHED.equals(action) || DISMISSED.equals(action)) {
            if (generation != null && generation.equals(intent.getStringExtra("generation"))) {
                if (DISMISSED.equals(action)) stopSelf(); else firstTouch(SystemClock.elapsedRealtime());
            } else if (generation == null) stopSelf();
            return START_NOT_STICKY;
        }
        releaseMonitor(); cancelActions(); main.removeCallbacksAndMessages(null);
        generation = java.util.UUID.randomUUID().toString(); touched = 0;
        computerName = intent.getStringExtra(SessionAudit.COMPUTER_NAME);
        Bundle extras = intent.getExtras(); monitor = extras == null ? null : extras.getBinder("touchMonitor");
        NotificationManager manager = getSystemService(NotificationManager.class);
        manager.createNotificationChannel(new NotificationChannel("remote-use", "Remote use history", NotificationManager.IMPORTANCE_DEFAULT));
        Notification notification = notification();
        if (Build.VERSION.SDK_INT >= 34) startForeground(NOTIFICATION, notification, ServiceInfo.FOREGROUND_SERVICE_TYPE_SPECIAL_USE);
        else startForeground(NOTIFICATION, notification);
        main.post(localUseCheck);
        if (monitor != null) {
            final IBinder current = monitor;
            Binder observer = new Binder() {
                @Override protected boolean onTransact(int code, Parcel data, Parcel reply, int transactionFlags) throws RemoteException {
                    if (code != RemoteUseWarning.TOUCH) return super.onTransact(code, data, reply, transactionFlags);
                    data.enforceInterface(RemoteUseWarning.DESCRIPTOR);
                    long when = data.readLong();
                    main.post(() -> { if (monitor == current) firstTouch(when); });
                    return true;
                }
            };
            Parcel data = Parcel.obtain();
            try {
                data.writeInterfaceToken(RemoteUseWarning.DESCRIPTOR); data.writeStrongBinder(observer);
                monitor.transact(RemoteUseWarning.ATTACH, data, null, IBinder.FLAG_ONEWAY);
            } catch (RemoteException ignored) { releaseMonitor(); }
            finally { data.recycle(); }
        }
        return START_NOT_STICKY;
    }
    private PendingIntent action(String action) {
        Intent intent = new Intent(this, RemoteUseWarningService.class).setAction(action)
            .setData(android.net.Uri.parse("droidmirror://remote-use/" + generation)).putExtra("generation", generation);
        return PendingIntent.getService(this, 0, intent, PendingIntent.FLAG_IMMUTABLE | PendingIntent.FLAG_UPDATE_CURRENT);
    }
    private void cancelActions() {
        if (generation == null) return;
        action(TOUCHED).cancel(); action(DISMISSED).cancel();
    }
    private Notification notification() {
        Notification.Builder builder = new Notification.Builder(this, "remote-use")
            .setSmallIcon(R.drawable.ic_screen_share).setContentTitle(SessionAudit.TITLE).setContentText(SessionAudit.text(computerName))
            .setStyle(new Notification.BigTextStyle().bigText(SessionAudit.text(computerName)))
            .setOngoing(true).setAutoCancel(false).setOnlyAlertOnce(true).setShowWhen(false)
            .setCategory(Notification.CATEGORY_STATUS).setVisibility(Notification.VISIBILITY_PUBLIC)
            .setContentIntent(action(TOUCHED)).setDeleteIntent(action(DISMISSED));
        if (Build.VERSION.SDK_INT >= 36) {
            builder.setShortCriticalText("Ended");
            Bundle extras = new Bundle(); extras.putBoolean("android.requestPromotedOngoing", true); builder.addExtras(extras);
        }
        return builder.build();
    }
    private void firstTouch(long when) {
        if (touched != 0) return;
        main.removeCallbacks(localUseCheck);
        touched = Math.max(1, Math.min(when, SystemClock.elapsedRealtime()));
        // NotificationManager also owns the timeout, so process suspension cannot leave a stale warning.
        long remaining = Math.max(1, touched + 5000 - SystemClock.elapsedRealtime());
        getSystemService(NotificationManager.class).notify(NOTIFICATION,
            Notification.Builder.recoverBuilder(this, notification()).setTimeoutAfter(remaining).build());
        main.postDelayed(this::stopSelf, remaining);
    }
    private void releaseMonitor() {
        if (monitor == null) return;
        Parcel data = Parcel.obtain();
        try { data.writeInterfaceToken(RemoteUseWarning.DESCRIPTOR); monitor.transact(RemoteUseWarning.DISMISS, data, null, IBinder.FLAG_ONEWAY); }
        catch (RemoteException ignored) {}
        finally { data.recycle(); monitor = null; }
    }
    @Override public void onDestroy() {
        main.removeCallbacksAndMessages(null); releaseMonitor(); cancelActions(); unregisterReceiver(unlocked);
        stopForeground(STOP_FOREGROUND_REMOVE); super.onDestroy();
    }
}
