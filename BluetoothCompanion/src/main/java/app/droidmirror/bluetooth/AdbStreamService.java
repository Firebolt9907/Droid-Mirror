package app.droidmirror.bluetooth;

import android.app.Notification;
import android.app.NotificationManager;
import android.app.Service;
import android.content.Intent;
import android.content.pm.ServiceInfo;
import android.os.*;
import com.genymobile.scrcpy.AdbStreamSession;
import java.util.UUID;

/** Shell-only entry point; the shell server owns capture and the lifetime of this notification. */
public final class AdbStreamService extends Service {
    private static final int NOTIFICATION = 3;
    private final Handler main = new Handler(Looper.getMainLooper());
    private IBinder owner;
    private IBinder.DeathRecipient death;
    private String token;
    private long started;
    private boolean dismissed;
    private Binder eventsFor(IBinder generation) {
        return new Binder() {
            @Override protected boolean onTransact(int code, Parcel data, Parcel reply, int flags) throws RemoteException {
                if (code != AdbStreamSession.ENDED) return super.onTransact(code, data, reply, flags);
                data.enforceInterface(AdbStreamSession.DESCRIPTOR);
                main.post(() -> { if (owner == generation) finishSession(); });
                return true;
            }
        };
    }

    @Override public IBinder onBind(Intent intent) { return null; }

    private Notification notification() {
        return StreamNotifications.streaming(this, token, started, dismissed);
    }

    @Override public int onStartCommand(Intent intent, int flags, int startId) {
        if (intent == null) { finishSession(); return START_NOT_STICKY; }
        String action = intent.getAction();
        if (StreamNotifications.DISCONNECT.equals(action) || StreamNotifications.DISMISSED.equals(action)
                || StreamNotifications.MINIMIZE.equals(action)) {
            if (token != null && token.equals(intent.getStringExtra(StreamNotifications.TOKEN))) {
                if (StreamNotifications.MINIMIZE.equals(action)) {
                    StreamNotifications.minimizeOnMac();
                } else if (StreamNotifications.DISCONNECT.equals(action)) {
                    AdbStreamSession.signal(owner, AdbStreamSession.DISCONNECT);
                    finishSession();
                } else {
                    dismissed = true;
                    getSystemService(NotificationManager.class).notify(NOTIFICATION, notification());
                }
            }
            if (owner == null) stopSelfResult(startId);
            return START_NOT_STICKY;
        }
        Bundle extras = intent.getExtras();
        IBinder next = extras == null ? null : extras.getBinder("owner");
        if (next == null) { if (owner == null) stopSelfResult(startId); return START_NOT_STICKY; }
        if (owner != null && owner.isBinderAlive() && !owner.equals(next)) {
            // One promoted stream at a time; keep the existing session's controls valid.
            AdbStreamSession.signal(next, AdbStreamSession.DISCONNECT);
            return START_NOT_STICKY;
        }
        finishSessionState();
        SessionAudit.clear(this);
        owner = next;
        token = "adb-" + UUID.randomUUID();
        started = intent.getLongExtra(StreamNotifications.STARTED, SystemClock.elapsedRealtime());
        dismissed = false;
        if (Build.VERSION.SDK_INT >= 34) startForeground(NOTIFICATION, notification(), ServiceInfo.FOREGROUND_SERVICE_TYPE_SPECIAL_USE);
        else startForeground(NOTIFICATION, notification());
        final IBinder generation = owner;
        death = () -> main.post(() -> { if (owner == generation) finishSession(); });
        try {
            owner.linkToDeath(death, 0);
            Parcel data = Parcel.obtain();
            try {
                data.writeInterfaceToken(AdbStreamSession.DESCRIPTOR);
                data.writeStrongBinder(eventsFor(generation));
                owner.transact(AdbStreamSession.ATTACH, data, null, IBinder.FLAG_ONEWAY);
            } finally { data.recycle(); }
        } catch (RemoteException e) { finishSession(); }
        return START_NOT_STICKY;
    }

    private void finishSessionState() {
        if (owner != null && death != null) {
            try { owner.unlinkToDeath(death, 0); } catch (RuntimeException ignored) {}
        }
        if (token != null) StreamNotifications.ended(this, token);
        owner = null; death = null; token = null;
    }
    private void finishSession() {
        finishSessionState();
        stopForeground(STOP_FOREGROUND_REMOVE);
        stopSelf();
    }
    @Override public void onDestroy() { finishSessionState(); super.onDestroy(); }
}
