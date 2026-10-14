package app.droidmirror.bluetooth;

import android.content.Context;
import android.os.IBinder;
import android.os.RemoteException;
import android.os.ParcelFileDescriptor;
import android.os.SystemClock;
import java.util.concurrent.Executors;
import java.util.concurrent.ScheduledExecutorService;
import java.util.concurrent.TimeUnit;

/** Shell daemon: display recovery, local-use detection and crash-surviving session audit. */
public final class DisplayGuardService extends IDisplayGuard.Stub {
    private final DisplayLease lease = new DisplayLease(new PhysicalDisplayPower(), SystemClock::elapsedRealtime);
    private final LogicalDisplayPower logical = new LogicalDisplayPower();
    private final RemoteSession session = new RemoteSession(SystemClock::elapsedRealtime, this::ended);
    private final ScheduledExecutorService watchdog = Executors.newSingleThreadScheduledExecutor();
    private IBinder owner;
    private IBinder.DeathRecipient death;
    private IStreamEvents observer;
    private final java.util.LinkedHashMap<Object, Boolean> audits = new java.util.LinkedHashMap<>();
    private PrivilegedCapture capture;
    private Object captureGeneration;
    private long captureStarted;
    private String captureError = "";
    private long lastActivity;

    public DisplayGuardService() {
        watchdog.scheduleWithFixedDelay(() -> {
            synchronized (this) {
                boolean interactive = true;
                try { interactive = logical.interactive(); } catch (Exception ignored) {}
                session.tick(interactive); lease.tick();
                if (session.owner() != null && interactive && SystemClock.elapsedRealtime() - lastActivity >= 1000) {
                    lastActivity = SystemClock.elapsedRealtime();
                    try { logical.keepAwake(); } catch (Exception ignored) {}
                }
                if (owner != null && !session.owns(owner) && SystemClock.elapsedRealtime() - captureStarted > 10000) {
                    closeCapture(); unlinkOwner();
                }
            }
        }, 100, 100, TimeUnit.MILLISECONDS);
        Runtime.getRuntime().addShutdownHook(new Thread(() -> {
            synchronized (this) { session.finish(owner, RemoteSession.GUARD_STOP); closeCapture(); lease.recover(); }
        }, "DisplayRecovery"));
    }
    public DisplayGuardService(Context context) { this(); }
    @Override public synchronized boolean startCapture(IBinder token, IStreamEvents events, ParcelFileDescriptor output) {
        if (token == null || owner != null || capture != null || output == null || lease.isRestoreNeeded()) {
            if (output != null) try { output.close(); } catch (java.io.IOException ignored) {}
            return false;
        }
        IBinder.DeathRecipient recipient = () -> {
            synchronized (DisplayGuardService.this) {
                if (owner == token) { session.finish(token, RemoteSession.APP_DIED); closeCapture(); unlinkOwner(); }
            }
        };
        try {
            token.linkToDeath(recipient, 0);
            owner = token; death = recipient; observer = events;
            if (!token.isBinderAlive()) throw new RemoteException("App died before capture");
            // Wake through Android's normal power policy for unattended capture.
            // Do not dismiss keyguard or alter the user's configured lock policy.
            if (!logical.interactive()) logical.wake();
            if (!session.begin(token, 10000)) throw new IllegalStateException("Remote session already active");
            Object generation = new Object(); captureGeneration = generation;
            captureStarted = SystemClock.elapsedRealtime(); captureError = "";
            capture = new PrivilegedCapture(output, () -> watchdog.execute(() -> {
                synchronized (DisplayGuardService.this) {
                    if (captureGeneration == generation) {
                        session.finish(token, RemoteSession.STOP); closeCapture(); capture = null; unlinkOwner();
                    }
                }
            }));
            return true;
        } catch (Exception | LinkageError | AssertionError failure) {
            captureError = "Privileged capture unavailable (" + failure.getClass().getSimpleName() + ")";
            try { output.close(); } catch (java.io.IOException ignored) {}
            session.finish(token, RemoteSession.STOP); closeCapture(); unlinkOwner(); return false;
        }
    }
    @Override public synchronized boolean acquire(IBinder token, IStreamEvents events, boolean panelOff) {
        if (owner != token || token == null || !session.heartbeat(token)) return false;
        observer = events;
        if (panelOff) lease.acquire(token);
        return true;
    }
    private void closeCapture() { if (capture != null) capture.close(); }
    @Override public synchronized boolean heartbeat(IBinder token) {
        boolean alive = session.heartbeat(token);
        if (alive && lease.owns(token)) lease.heartbeat(token);
        if (!alive && owner == token) { closeCapture(); unlinkEndedOwner(); }
        return alive;
    }
    @Override public synchronized boolean release(IBinder token) {
        boolean audited = session.owns(token) ? session.finish(token, RemoteSession.STOP)
            : Boolean.TRUE.equals(audits.get(token));
        if (owner == token) { closeCapture(); unlinkOwner(); }
        return audited;
    }
    @Override public synchronized void localUse(IBinder token) {
        session.finish(token, RemoteSession.LOCAL_USE); unlinkEndedOwner();
    }
    @Override public synchronized boolean restoreDisplay() {
        session.finish(owner, RemoteSession.RECOVERY);
        closeCapture(); boolean restored = lease.recover(); unlinkOwner(); return restored;
    }
    @Override public synchronized String getLastError() { return captureError.isEmpty() ? lease.getLastError() : captureError; }
    private boolean ended(Object token, int cause) {
        IStreamEvents events = observer;
        boolean awake = false;
        try {
            if (cause == RemoteSession.LOCAL_USE) {
                logical.lock(); // Never deliberately wake an unlocked phone.
                if (!lease.recover()) throw new IllegalStateException("Panel restoration pending");
                logical.wake(); awake = true;
            } else lease.release(token);
        } catch (Exception failure) { lease.recover(); }
        // Recovery and event delivery precede the slower notification command.
        if (events != null) {
            try { events.onEnded(cause, awake); } catch (RemoteException ignored) {}
        }
        closeCapture(); unlinkEndedOwner();
        boolean posted = SessionAudit.shell();
        audits.put(token, posted);
        if (audits.size() > 16) audits.remove(audits.keySet().iterator().next());
        return posted;
    }
    private void unlinkEndedOwner() { if (owner != null && !session.owns(owner)) unlinkOwner(); }
    private void unlinkOwner() {
        if (owner != null && death != null) {
            try { owner.unlinkToDeath(death, 0); } catch (RuntimeException ignored) {}
        }
        owner = null; death = null; observer = null;
    }
    @Override public void destroy() {
        synchronized (this) {
            session.finish(owner, RemoteSession.GUARD_STOP);
            if (!lease.recover()) return;
            closeCapture(); unlinkOwner(); watchdog.shutdown();
        }
        System.exit(0); // Do not hold this monitor while shutdown hooks acquire it.
    }
}
