package app.droidmirror.bluetooth;

import android.app.Notification;
import android.app.NotificationManager;
import android.app.Service;
import android.content.Intent;
import android.content.pm.ServiceInfo;
import android.os.*;
import com.genymobile.scrcpy.AdbStreamSession;
import java.security.MessageDigest;
import java.security.SecureRandom;
import java.util.UUID;

/** Shell-only entry point; the shell server owns capture and the lifetime of this notification. */
public final class AdbStreamService extends Service {
    private static final int NOTIFICATION = 3;
    private static final int ROOT_UID = 0;
    private static final int SHELL_UID = 2000;
    private final Handler main = new Handler(Looper.getMainLooper());
    private IBinder owner;
    private IBinder.DeathRecipient death;
    private String token;
    private long started;
    private boolean dismissed;

    static void verifyCaller(IBinder target) throws RemoteException, SecurityException {
        if (target == null) throw new IllegalArgumentException("Target binder is null");
        final int[] verifiedUid = new int[]{-1};
        final byte[] nonce = new byte[16];
        new SecureRandom().nextBytes(nonce);
        final boolean[] nonceMatched = new boolean[]{false};

        Binder verifier = new Binder() {
            @Override protected boolean onTransact(int code, Parcel data, Parcel reply, int flags) throws RemoteException {
                if (code == 1) {
                    data.enforceInterface(AdbStreamSession.DESCRIPTOR);
                    byte[] received = data.createByteArray();
                    nonceMatched[0] = received != null && MessageDigest.isEqual(nonce, received);
                    verifiedUid[0] = Binder.getCallingUid();
                    if (reply != null) reply.writeNoException();
                    return true;
                }
                return super.onTransact(code, data, reply, flags);
            }
        };

        Parcel request = Parcel.obtain();
        Parcel reply = Parcel.obtain();
        try {
            request.writeInterfaceToken(AdbStreamSession.DESCRIPTOR);
            request.writeStrongBinder(verifier);
            request.writeByteArray(nonce);
            if (!target.transact(AdbStreamSession.VERIFY_CALLER, request, reply, 0)) {
                throw new SecurityException("Caller verification unavailable");
            }
            reply.readException();
        } finally {
            request.recycle();
            reply.recycle();
        }

        if (!nonceMatched[0] || (verifiedUid[0] != SHELL_UID && verifiedUid[0] != ROOT_UID)) {
            throw new SecurityException("Untrusted caller UID: " + verifiedUid[0]);
        }
    }

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
        try {
            verifyCaller(next);
        } catch (Exception error) {
            AdbStreamSession.signal(next, AdbStreamSession.DISCONNECT);
            if (owner == null) stopSelfResult(startId);
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
            if (intent.getBooleanExtra("prepareUnlock", false)) {
                verifyCaller(owner);
                byte[] pin = null;
                try {
                    pin = SavedUnlockPin.beginAttempt(this);
                    Parcel request = Parcel.obtain();
                    Parcel reply = Parcel.obtain();
                    try {
                        request.writeInterfaceToken(AdbStreamSession.DESCRIPTOR);
                        request.writeByteArray(pin);
                        if (!owner.transact(AdbStreamSession.PREPARE_UNLOCK, request, reply, 0))
                            throw new IllegalStateException("Unlock handshake unavailable");
                        reply.readException();
                        if (reply.readInt() != 1) throw new IllegalStateException("Automatic unlock failed");
                    } finally { request.recycle(); reply.recycle(); }
                    if (pin != null) SavedUnlockPin.completed(this);
                } catch (Exception error) {
                    AdbStreamSession.signal(owner, AdbStreamSession.DISCONNECT);
                    finishSession(); return START_NOT_STICKY;
                } finally { if (pin != null) java.util.Arrays.fill(pin, (byte) 0); }
            }
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
