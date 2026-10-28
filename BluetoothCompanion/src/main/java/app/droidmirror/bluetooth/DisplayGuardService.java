package app.droidmirror.bluetooth;

import com.genymobile.scrcpy.control.PinUnlock;

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
    private static final int ROOT_UID = 0;
    private static final int SHELL_UID = 2000;
    private final Context context;
    private final com.genymobile.scrcpy.control.IdleUhidKeyboard keyboard = new com.genymobile.scrcpy.control.IdleUhidKeyboard();
    private final DisplayLease lease = new DisplayLease(new PhysicalDisplayPower(), SystemClock::elapsedRealtime, keyboard::destroy);
    private final LogicalDisplayPower logical = new LogicalDisplayPower();
    private final RemoteSession session = new RemoteSession(SystemClock::elapsedRealtime, this::ended);
    private final ScheduledExecutorService watchdog = Executors.newSingleThreadScheduledExecutor();
    // Capture startup holds this service's monitor. Keep the physical panel guard
    // independent so Android's asynchronous wake cannot expose PIN entry while
    // that monitor is occupied by input injection or codec initialization.
    private final ScheduledExecutorService startupDisplay = Executors.newSingleThreadScheduledExecutor();
    private volatile IBinder startupOwner;
    private volatile IBinder cancelledStartup;
    private final java.util.concurrent.ExecutorService unlockInput = Executors.newSingleThreadExecutor();
    private IBinder owner;
    private IBinder.DeathRecipient death;
    private IStreamEvents observer;
    private final java.util.LinkedHashMap<Object, Boolean> audits = new java.util.LinkedHashMap<>();
    private PrivilegedCapture capture;
    private HapticListener haptics;
    private SilentHaptics silentHaptics;
    private SilentHaptics restoringHaptics;
    private Object hapticAttempt;
    private boolean hapticRestoreRunning;
    private long lastHapticRestore;
    private final java.util.concurrent.ExecutorService hapticCleanup = Executors.newSingleThreadExecutor();
    private BlackoutOverlay blackout;
    private TouchBlocker touchBlocker;
    private PrivilegedAudioCapture audio;
    private Object captureGeneration;
    private long captureStarted;
    private String captureError = "";
    private long lastActivity;
    private long lastAudioRecovery;
    private String computerName;

    private void checkCaller() {
        int callingUid = android.os.Binder.getCallingUid();
        if (callingUid == android.os.Process.myUid() || callingUid == ROOT_UID || callingUid == SHELL_UID) {
            return;
        }
        if (context != null && callingUid == context.getApplicationInfo().uid) {
            return;
        }
        throw new SecurityException("Unauthorized caller UID: " + callingUid);
    }

    public DisplayGuardService() { this(null); }
    public DisplayGuardService(Context context) {
        this.context = context;
        startupDisplay.scheduleWithFixedDelay(() -> {
            IBinder token = startupOwner;
            if (token == null) return;
            try { lease.tick(); lease.keepDark(token); }
            catch (Exception failure) { android.util.Log.w("DroidMirrorLease", "Startup panel guard could not reapply OFF"); }
        }, 0, 20, TimeUnit.MILLISECONDS);
        watchdog.scheduleWithFixedDelay(() -> {
            synchronized (this) {
                long now = SystemClock.elapsedRealtime();
                if (restoringHaptics != null && restoringHaptics.released()) restoringHaptics = null;
                if (restoringHaptics != null && !hapticRestoreRunning && now - lastHapticRestore >= 1000)
                    queueHapticRestore(restoringHaptics);
                if (silentHaptics != null) {
                    try {
                        if (!silentHaptics.healthy()) throw new IllegalStateException("Haptic trace stopped");
                        silentHaptics.heartbeat();
                    } catch (Exception failure) {
                        android.util.Log.w("DroidMirrorHaptics", "Restoring phone vibration after trace failure", failure);
                        stopSilentHaptics(owner);
                    }
                }
                if (audio != null && now - lastAudioRecovery >= 1000) {
                    lastAudioRecovery = now;
                    audio.retryRelease();
                }
                boolean interactive = true;
                try { interactive = logical.interactive(); } catch (Exception ignored) {}
                session.tick(interactive); lease.tick();
                if (blackout != null && session.owns(owner)) {
                    try {
                        if (touchBlocker == null || !touchBlocker.alive()) throw new IllegalStateException("Touch blocker ended");
                        blackout.update();
                    }
                    catch (Exception failure) {
                        captureError = "Phone blackout overlay unavailable; mirroring stopped.";
                        session.finish(owner, RemoteSession.RECOVERY);
                    }
                }
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
            synchronized (this) { session.finish(owner, RemoteSession.GUARD_STOP); keyboard.destroy(); closeBlackout(); closeCapture(); lease.recover(); }
        }, "DisplayRecovery"));
    }
    @Override public byte[] phoneAppearance() {
        checkCaller();
        // Context permission/compatibility checks must use the authorized shell,
        // not the unprivileged app making this Binder call.
        long identity = android.os.Binder.clearCallingIdentity();
        try { return PhoneAppearance.read(); }
        finally { android.os.Binder.restoreCallingIdentity(identity); }
    }
    @Override public synchronized boolean startCapture(IBinder token, IStreamEvents events, ParcelFileDescriptor output, ParcelFileDescriptor controls, String computerName, boolean panelOff, byte[] unlockPin, boolean blackoutOverlay, byte[] blackoutMessage) {
        checkCaller();
        if (token == null || owner != null || capture != null || output == null || controls == null || lease.isRestoreNeeded()) {
            if (output != null) try { output.close(); } catch (java.io.IOException ignored) {}
            if (unlockPin != null) java.util.Arrays.fill(unlockPin, (byte) 0);
            return false;
        }
        // A stale/conflicting caller cannot silently enable both display modes.
        final boolean usePanelOff = panelOff && !blackoutOverlay;
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
            if (unlockPin != null) java.util.Arrays.fill(unlockPin, (byte) 0);
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
            if (usePanelOff && !lease.acquire(token, 10000)) throw new IllegalStateException(lease.getLastError());
            if (usePanelOff) startupOwner = token;
            if (blackoutOverlay) {
                PrivilegedCapture.initialize();
                blackout = new BlackoutOverlay(blackoutMessage);
                touchBlocker = new TouchBlocker();
                blackout.update(); // Exclude and cover the display before waking or entering a PIN.
            }
            if (!logical.interactive()) logical.wake();
            if (blackout != null) blackout.reveal();
            if (usePanelOff) lease.keepDark(token);
            Object generation = new Object(); captureGeneration = generation;
            captureStarted = SystemClock.elapsedRealtime(); captureError = "";
            android.util.Log.i("DroidMirrorCapture", "Preparing privileged capture");
            capture = new PrivilegedCapture(output, controls, () -> watchdog.execute(() -> {
                synchronized (DisplayGuardService.this) {
                    if (captureGeneration == generation) {
                        session.finish(token, RemoteSession.STOP); closeCapture(); capture = null; unlinkOwner();
                    }
                }
            }), unlockPin != null);
            startStateHaptics();
            if (unlockPin != null) {
                byte[] pendingPin = unlockPin.clone();
                try {
                    unlockInput.execute(() -> completeUnlock(token, events, pendingPin, usePanelOff));
                } catch (RuntimeException rejected) {
                    java.util.Arrays.fill(pendingPin, (byte) 0); throw rejected;
                }
                // Header/configuration can reach the Mac decoder immediately.
                // Pixel frames remain gated until completeUnlock confirms success.
                return true;
            }
            keyboard.create();
            android.util.Log.i("DroidMirrorCapture", "Privileged capture startup returned");
            return true;
        } catch (Exception | LinkageError | AssertionError failure) {
            android.util.Log.e("DroidMirrorCapture", "Privileged capture startup failed", failure);
            captureError = failure instanceof PinUnlock.Failure ? failure.getMessage()
                : "Privileged capture unavailable (" + failure.getClass().getSimpleName() + ")";
            try { output.close(); } catch (java.io.IOException ignored) {}
            session.finish(token, RemoteSession.STOP); closeCapture(); unlinkOwner(); return false;
        } finally { if (unlockPin == null || capture == null) startupOwner = null; if (unlockPin != null) java.util.Arrays.fill(unlockPin, (byte) 0); }
    }
    private void completeUnlock(IBinder token, IStreamEvents events, byte[] pin, boolean panelOff) {
        synchronized (this) {
            try {
                if (owner != token || !session.owns(token) || capture == null || cancelledStartup == token) return;
                PrivilegedCapture.initialize();
                android.util.Log.i("DroidMirrorCapture", "Automatic unlock starting");
                PinUnlock.unlock(pin, new PinUnlock.Device() {
                    public boolean locked() throws Exception {
                        if (panelOff && !lease.owns(token)) throw new IllegalStateException("Startup display lease expired");
                        if (cancelledStartup == token || !token.isBinderAlive()) throw new RemoteException("Mirror startup cancelled");
                        return logical.locked();
                    }
                    public void key(int code) throws Exception {
                        if (panelOff) lease.keepDark(token);
                        if (!com.genymobile.scrcpy.device.Device.pressReleaseKeycode(code, 0,
                                com.genymobile.scrcpy.device.Device.INJECT_MODE_WAIT_FOR_FINISH))
                            throw new IllegalStateException("Unlock input unavailable");
                        if (panelOff) lease.keepDark(token);
                    }
                    public void sleep(long millis) { SystemClock.sleep(millis); }
                    public long now() { return SystemClock.elapsedRealtime(); }
                });
                // Credential success is independent of codec/transport startup.
                // An encoder failure must not keep a known-good PIN paused.
                if (events != null) events.onUnlockConfirmed();
                capture.unlockConfirmed();
                android.util.Log.i("DroidMirrorCapture", "Automatic unlock confirmed; releasing fresh video");
                keyboard.create();
            } catch (Exception | LinkageError | AssertionError failure) {
                android.util.Log.e("DroidMirrorCapture", "Automatic unlock startup failed", failure);
                captureError = failure instanceof PinUnlock.Failure ? failure.getMessage()
                    : "Automatic unlock failed; streaming can be retried with manual unlock.";
                session.finish(token, RemoteSession.UNLOCK_FAILED);
                closeCapture(); unlinkOwner();
            } finally {
                if (startupOwner == token) startupOwner = null;
                java.util.Arrays.fill(pin, (byte) 0);
            }
        }
    }
    @Override public synchronized boolean acquire(IBinder token, IStreamEvents events, boolean panelOff) {
        checkCaller();
        if (owner != token || token == null || !session.owns(token)) return false;
        observer = events;
        if (panelOff && !lease.heartbeat(token)) return false;
        return session.heartbeat(token);
    }
    @Override public synchronized boolean startAudio(IBinder token, ParcelFileDescriptor output) {
        checkCaller();
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
        checkCaller();
        if (token == null || owner != token) return;
        if (audio != null) audio.close(); // Retain until release/volume restoration completes.
    }
    private void closeCapture() {
        releaseSilentHaptics();
        if (haptics != null) { haptics.close(); haptics = null; }
        stopAudio(owner);
        keyboard.destroy();
        if (capture != null) { capture.close(); capture = null; }
        closeBlackout();
    }
    private void emitHaptic(Object generation, IBinder token) {
        synchronized (this) {
            if (captureGeneration != generation || capture == null || !session.owns(token)) return;
            try { if (observer != null) observer.onHaptic(); }
            catch (RemoteException ignored) {}
        }
    }
    private void startStateHaptics() {
        if (haptics != null || silentHaptics != null || capture == null) return;
        Object generation = captureGeneration; IBinder token = owner;
        try { haptics = new HapticListener(() -> emitHaptic(generation, token)); }
        catch (Exception | LinkageError unavailable) {
            android.util.Log.w("DroidMirrorHaptics", "State listener unavailable", unavailable);
        }
    }
    @Override public boolean startSilentHaptics(IBinder token, String originalSetting) {
        checkCaller();
        int user = android.os.Binder.getCallingUid() / 100000;
        Object generation, attempt = new Object();
        synchronized (this) {
            if (token == null || owner != token || !session.owns(token) || capture == null || restoringHaptics != null || hapticAttempt != null) return false;
            if (silentHaptics != null) return silentHaptics.healthy();
            generation = captureGeneration; hapticAttempt = attempt;
        }
        long identity = android.os.Binder.clearCallingIdentity();
        SilentHaptics started = null;
        try {
            started = new SilentHaptics(user, originalSetting, () -> emitHaptic(generation, token), () -> {
                synchronized (DisplayGuardService.this) { return hapticAttempt == attempt && owner == token && session.owns(token); }
            });
            synchronized (this) {
                if (hapticAttempt != attempt || owner != token || !session.owns(token)) return false;
                silentHaptics = started; started = null;
                if (haptics != null) { haptics.close(); haptics = null; }
                return true;
            }
        } catch (Exception | LinkageError unavailable) {
            android.util.Log.w("DroidMirrorHaptics", "Phone vibration retained; request tracing unavailable", unavailable);
            return false;
        } finally {
            if (started != null) started.close();
            synchronized (this) { if (hapticAttempt == attempt) hapticAttempt = null; }
            android.os.Binder.restoreCallingIdentity(identity);
        }
    }
    @Override public synchronized void stopSilentHaptics(IBinder token) {
        checkCaller();
        if (token == null || owner != token) return;
        releaseSilentHaptics();
        startStateHaptics();
    }
    private void releaseSilentHaptics() {
        hapticAttempt = null;
        SilentHaptics old = silentHaptics; silentHaptics = null;
        if (old == null) return;
        old.requestRestore(); // Signal before cleanup can queue behind slow driver/trace work.
        restoringHaptics = old;
        queueHapticRestore(old);
    }
    private void queueHapticRestore(SilentHaptics old) {
        hapticRestoreRunning = true; lastHapticRestore = SystemClock.elapsedRealtime();
        hapticCleanup.execute(() -> {
            try { old.close(); }
            finally {
                synchronized (DisplayGuardService.this) {
                    hapticRestoreRunning = false;
                    if (restoringHaptics == old && old.released()) restoringHaptics = null;
                }
            }
        });
    }
    @Override public synchronized boolean upgradeVideo(IBinder token, int maxSize, int fps, int bitRate) {
        checkCaller();
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
        checkCaller();
        if (token==null || owner!=token || !session.owns(token) || capture==null) return false;
        try { capture.restoreBluetoothVideo(); return true; }
        catch (RuntimeException failed) {
            android.util.Log.w("DroidMirrorCapture","Bluetooth quality restore failed",failed); return false;
        }
    }
    @Override public synchronized boolean updateBlackout(IBinder token, byte[] message) {
        checkCaller();
        if (token == null || owner != token || !session.owns(token) || blackout == null) return false;
        try { blackout.setMessage(message); return true; }
        catch (Exception failure) {
            android.util.Log.w("DroidMirrorBlackout", "AOD refresh failed; retaining blackout", failure);
            return false;
        }
    }
    @Override public synchronized boolean heartbeat(IBinder token) {
        boolean alive = session.heartbeat(token);
        if (alive && lease.owns(token)) lease.heartbeat(token);
        if (!alive && owner == token) { closeCapture(); unlinkEndedOwner(); }
        return alive;
    }
    @Override public boolean release(IBinder token) {
        if (startupOwner == token) cancelledStartup = token;
        synchronized (this) {
        boolean audited = session.owns(token) ? session.finish(token, RemoteSession.STOP)
            : Boolean.TRUE.equals(audits.get(token));
        if (owner == token) { closeCapture(); unlinkOwner(); }
        return audited;
        }
    }
    @Override public synchronized void localUse(IBinder token) {
        checkCaller();
        session.finish(token, RemoteSession.LOCAL_USE); unlinkEndedOwner();
    }
    @Override public synchronized boolean restoreDisplay() {
        checkCaller();
        session.finish(owner, RemoteSession.RECOVERY);
        keyboard.destroy();
        closeCapture(); boolean restored = lease.recover(); unlinkOwner(); return restored;
    }
    @Override public boolean grantSecureSettings() {
        checkCaller();
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
        releaseSilentHaptics(); // Local phone feedback must return before display recovery or teardown.
        IStreamEvents events = observer;
        boolean awake = false;
        try {
            logical.lock(); // End every remote session behind the keyguard before restoring the panel.
            if (cause == RemoteSession.LOCAL_USE) {
                SystemClock.sleep(500); // Let the lock screen settle before turning the panel on.
                if (!lease.recover()) throw new IllegalStateException("Panel restoration pending");
                closeCapture(); // Stop remote input before waking for the local user.
                logical.wake(); awake = true;
                if (blackout != null) blackout.fadeOut();
                closeBlackout();
            } else {
                // Stop capture before sleeping so input/codec shutdown cannot wake
                // Android after its transition back to the configured AOD policy.
                closeCapture();
                if (cause == RemoteSession.STOP && blackout != null) blackout.fadeOut();
                logical.sleep();
                lease.release(token);
            }
        } catch (Exception failure) {
            android.util.Log.e("DroidMirrorLease", "Lock or display recovery failed", failure);
            lease.recover();
        }
        closeBlackout();
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
    private void closeBlackout() {
        if (touchBlocker != null) { touchBlocker.close(); touchBlocker = null; }
        if (blackout != null) { blackout.close(); blackout = null; }
    }
    private void unlinkEndedOwner() { if (owner != null && !session.owns(owner)) unlinkOwner(); }
    private void unlinkOwner() {
        if (owner != null && death != null) {
            try { owner.unlinkToDeath(death, 0); } catch (RuntimeException ignored) {}
        }
        owner = null; death = null; observer = null;
    }
    @Override public void destroy() {
        checkCaller();
        synchronized (this) {
            session.finish(owner, RemoteSession.GUARD_STOP);
            keyboard.destroy();
            if (!lease.recover()) return;
            closeCapture(); unlinkOwner(); watchdog.shutdown(); startupDisplay.shutdown(); unlockInput.shutdown(); hapticCleanup.shutdown();
        }
        System.exit(0); // Do not hold this monitor while shutdown hooks acquire it.
    }
}
