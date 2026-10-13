package app.droidmirror.bluetooth;

import android.content.Context;
import android.os.IBinder;
import android.os.RemoteException;
import android.os.SystemClock;
import java.util.concurrent.Executors;
import java.util.concurrent.ScheduledExecutorService;
import java.util.concurrent.TimeUnit;

/** A Shizuku daemon user service (shell/root UID), not an Android application Service. */
public final class DisplayGuardService extends IDisplayGuard.Stub {
    private final DisplayLease lease = new DisplayLease(new PhysicalDisplayPower(), SystemClock::elapsedRealtime);
    private final ScheduledExecutorService watchdog = Executors.newSingleThreadScheduledExecutor();
    private IBinder owner;
    private IBinder.DeathRecipient death;

    public DisplayGuardService() {
        watchdog.scheduleWithFixedDelay(() -> {
            synchronized (this) { lease.tick(); unlinkEndedOwner(); }
        }, 100, 100, TimeUnit.MILLISECONDS);
        Runtime.getRuntime().addShutdownHook(new Thread(lease::recover, "DisplayRecovery"));
    }
    public DisplayGuardService(Context context) { this(); }

    @Override public synchronized boolean acquire(IBinder token) {
        if (token == null || owner != null || lease.isRestoreNeeded()) return false;
        IBinder.DeathRecipient recipient = () -> {
            synchronized (DisplayGuardService.this) { lease.release(token); unlinkEndedOwner(); }
        };
        try {
            // Arm process-death recovery BEFORE touching physical display power.
            token.linkToDeath(recipient, 0);
            owner = token; death = recipient;
            if (!token.isBinderAlive() || !lease.acquire(token)) { unlinkOwner(); return false; }
            return true;
        } catch (RemoteException alreadyDead) { unlinkOwner(); return false; }
    }
    @Override public synchronized boolean heartbeat(IBinder token) {
        boolean alive = lease.heartbeat(token); unlinkEndedOwner(); return alive;
    }
    @Override public synchronized boolean release(IBinder token) {
        boolean restored = lease.release(token); unlinkEndedOwner(); return restored;
    }
    @Override public synchronized boolean restoreDisplay() {
        boolean restored = lease.recover(); unlinkEndedOwner(); return restored;
    }
    @Override public synchronized String getLastError() { return lease.getLastError(); }
    private void unlinkEndedOwner() { if (owner != null && !lease.owns(owner)) unlinkOwner(); }
    private void unlinkOwner() {
        if (owner != null && death != null) {
            try { owner.unlinkToDeath(death, 0); } catch (RuntimeException ignored) {}
        }
        owner = null; death = null;
    }
    @Override public synchronized void destroy() {
        if (!lease.recover()) return; // Keep retrying ON rather than deliberately exit with a dark panel.
        unlinkOwner(); watchdog.shutdown(); System.exit(0);
    }
}
