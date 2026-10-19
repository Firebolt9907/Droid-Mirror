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
    private final com.genymobile.scrcpy.control.IdleUhidKeyboard keyboard = new com.genymobile.scrcpy.control.IdleUhidKeyboard();
    private final DisplayLease lease = new DisplayLease(new PhysicalDisplayPower(), SystemClock::elapsedRealtime, keyboard::destroy);
    private final LogicalDisplayPower logical = new LogicalDisplayPower();
    private final RemoteSession session = new RemoteSession(SystemClock::elapsedRealtime, this::ended);
    private final ScheduledExecutorService watchdog = Executors.newSingleThreadScheduledExecutor();
    private IBinder owner;
    private IBinder.DeathRecipient death;
    private IStreamEvents observer;
    private final java.util.LinkedHashMap<Object, Boolean> audits = new java.util.LinkedHashMap<>();
    private PrivilegedCapture capture;
    private PrivilegedAudioCapture audio;
    private Object captureGeneration;
    private long captureStarted;
    private String captureError = "";
    private long lastActivity;
    private long lastAudioRecovery;
    private String computerName;

    public DisplayGuardService() {
        watchdog.scheduleWithFixedDelay(() -> {
            synchronized (this) {
                long now = SystemClock.elapsedRealtime();
                if (audio != null && now - lastAudioRecovery >= 1000) {
                    lastAudioRecovery = now;
                    audio.retryRelease();
                }
                boolean interactive = true;
                try { interactive = logical.interactive(); } catch (Exception ignored) {}
                session.tick(interactive); lease.tick();
                if (lease.owns(owner) && SystemClock.elapsedRealtime() - captureStarted < 1000) {
                    try { lease.keepDark(owner); } catch (Exception failure) {
                        session.finish(owner, RemoteSession.RECOVERY);
                    }
                }
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
            synchronized (this) { session.finish(owner, RemoteSession.GUARD_STOP); keyboard.destroy(); closeCapture(); lease.recover(); }
        }, "DisplayRecovery"));
    }
    public DisplayGuardService(Context context) { this(); }
    @Override public byte[] phoneAppearance() { return PhoneAppearance.read(); }
    @Override public synchronized boolean startCapture(IBinder token, IStreamEvents events, ParcelFileDescriptor output, ParcelFileDescriptor controls, String computerName, boolean panelOff) {
        if (token == null || owner != null || capture != null || output == null || controls == null || lease.isRestoreNeeded()) {
            if (output != null) try { output.close(); } catch (java.io.IOException ignored) {}
            return false;
        }
        this.computerName = computerName;
        // Check before owning a session: rejecting local use must not lock, wake,
        // capture, or turn off the phone the person is holding.
        captureError = "";
        try {
            if (logical.inUse()) captureError = PhoneUsePolicy.ERROR;
        } catch (Exception failure) {
            captureError = "Could not check whether the phone is in use. Try again.";
        }
        if (!captureError.isEmpty()) {
            try { output.close(); } catch (java.io.IOException ignored) {}
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
            if (!session.begin(token, 10000)) throw new IllegalStateException("Remote session already active");
            // Own recovery before waking: encoder/transport startup must not leave the
            // physical lock screen visible while waiting for the first Mac frame.
            if (panelOff && !lease.acquire(token, 10000)) throw new IllegalStateException(lease.getLastError());
            if (!logical.interactive()) logical.wake();
            if (panelOff) lease.keepDark(token);
            Object generation = new Object(); captureGeneration = generation;
            captureStarted = SystemClock.elapsedRealtime(); captureError = "";
            capture = new PrivilegedCapture(output, controls, () -> watchdog.execute(() -> {
                synchronized (DisplayGuardService.this) {
                    if (captureGeneration == generation) {
                        session.finish(token, RemoteSession.STOP); closeCapture(); capture = null; unlinkOwner();
                    }
                }
            }));
            keyboard.create();
            return true;
        } catch (Exception | LinkageError | AssertionError failure) {
            android.util.Log.e("DroidMirrorCapture", "Privileged capture startup failed", failure);
            captureError = "Privileged capture unavailable (" + failure.getClass().getSimpleName() + ")";
            try { output.close(); } catch (java.io.IOException ignored) {}
            session.finish(token, RemoteSession.STOP); closeCapture(); unlinkOwner(); return false;
        }
    }
    @Override public synchronized boolean acquire(IBinder token, IStreamEvents events, boolean panelOff) {
        if (owner != token || token == null || !session.owns(token)) return false;
        observer = events;
        if (panelOff && !lease.heartbeat(token)) return false;
        return session.heartbeat(token);
    }
    @Override public synchronized boolean startAudio(IBinder token, ParcelFileDescriptor output) {
        if (audio != null && audio.isReleased()) audio = null;
        if (token == null || owner != token || !session.owns(token) || capture == null || audio != null
                || android.os.Build.VERSION.SDK_INT < 31) {
            if (output != null) try { output.close(); } catch (java.io.IOException ignored) {}
            return false;
        }
        try { audio = new PrivilegedAudioCapture(output); return true; }
        catch (Exception error) {
            if (output != null) try { output.close(); } catch (java.io.IOException ignored) {}
            android.util.Log.w("DroidMirrorAudio", "Audio capture unavailable", error); return false;
        }
    }
    @Override public synchronized void stopAudio(IBinder token) {
        if (token == null || owner != token) return;
        if (audio != null) audio.close(); // Retain until release/volume restoration completes.
    }
    private void closeCapture() { stopAudio(owner); keyboard.destroy(); if (capture != null) { capture.close(); capture = null; } }
    @Override public synchronized boolean upgradeVideo(IBinder token, int maxSize, int fps, int bitRate) {
        if (token == null || owner != token || !session.owns(token) || capture == null) return false;
        try {
            capture.upgradeVideo(new WirelessVideoProfile(maxSize, fps, bitRate));
            return true;
        } catch (Exception invalid) {
            android.util.Log.w("DroidMirrorCapture", "Wi-Fi quality request failed", invalid);
            return false;
        }
    }
    @Override public synchronized boolean restoreBluetoothVideo(IBinder token) {
        if (token==null || owner!=token || !session.owns(token) || capture==null) return false;
        try { capture.restoreBluetoothVideo(); return true; }
        catch (RuntimeException failed) {
            android.util.Log.w("DroidMirrorCapture","Bluetooth quality restore failed",failed); return false;
        }
    }
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
        keyboard.destroy();
        closeCapture(); boolean restored = lease.recover(); unlinkOwner(); return restored;
    }
    @Override public boolean grantSecureSettings() {
        // Fixed package and permission: this is not an arbitrary privileged command API.
        int user = android.os.Binder.getCallingUid() / 100000;
        Process command = null;
        try {
            command = new ProcessBuilder("/system/bin/cmd", "package", "grant", "--user", Integer.toString(user),
                "app.droidmirror.bluetooth", "android.permission.WRITE_SECURE_SETTINGS")
                .redirectErrorStream(true).redirectOutput(new java.io.File("/dev/null")).start();
            if (!command.waitFor(5, TimeUnit.SECONDS)) { command.destroyForcibly(); return false; }
            return command.exitValue() == 0;
        } catch (java.io.IOException failure) { return false; }
        catch (InterruptedException interrupted) { Thread.currentThread().interrupt(); return false; }
        finally { if (command != null) command.destroy(); }
    }
    @Override public synchronized String getLastError() { return captureError.isEmpty() ? lease.getLastError() : captureError; }
    private boolean ended(Object token, int cause) {
        android.util.Log.i("DroidMirrorLease", "Remote session ended, cause=" + cause);
        IStreamEvents events = observer;
        boolean awake = false;
        try {
            logical.lock(); // End every remote session behind the keyguard before restoring the panel.
            if (cause == RemoteSession.LOCAL_USE) {
                SystemClock.sleep(500); // Let the lock screen settle before turning the panel on.
                if (!lease.recover()) throw new IllegalStateException("Panel restoration pending");
                logical.wake(); awake = true;
            } else {
                // Stop capture before sleeping so input/codec shutdown cannot wake
                // Android after its transition back to the configured AOD policy.
                closeCapture();
                logical.sleep();
                lease.release(token);
            }
        } catch (Exception failure) {
            android.util.Log.e("DroidMirrorLease", "Lock or display recovery failed", failure);
            lease.recover();
        }
        // Recovery and event delivery precede the slower notification command.
        if (events != null) {
            try { events.onEnded(cause, awake); } catch (RemoteException ignored) {}
        }
        closeCapture(); unlinkEndedOwner();
        boolean posted = SessionAudit.shell(computerName);
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
            keyboard.destroy();
            if (!lease.recover()) return;
            closeCapture(); unlinkOwner(); watchdog.shutdown();
        }
        System.exit(0); // Do not hold this monitor while shutdown hooks acquire it.
    }
}
