package com.genymobile.scrcpy;

import android.content.ComponentName;
import android.content.Intent;
import android.os.Binder;
import android.os.Bundle;
import android.os.IBinder;
import android.os.Looper;
import android.os.Parcel;
import android.os.RemoteException;
import android.os.SystemClock;
import com.genymobile.scrcpy.wrappers.ServiceManager;
import java.io.BufferedReader;
import java.io.InputStreamReader;
import java.util.concurrent.TimeUnit;

/** A short-lived shell helper outlives capture, including server/app death and guard shutdown. */
public final class RemoteUseWarning {
    public static final String DESCRIPTOR = "app.droidmirror.RemoteUseWarning";
    public static final int ATTACH = IBinder.FIRST_CALL_TRANSACTION, DISMISS = ATTACH + 1, TOUCH = ATTACH + 2;
    private Process input;
    private IBinder observer;
    private IBinder.DeathRecipient death;
    private long touched;
    private boolean closed;
    private final Looper loop = Looper.myLooper();
    private final Binder controller = new Binder() {
        @Override protected boolean onTransact(int code, Parcel data, Parcel reply, int flags) throws RemoteException {
            if (code != ATTACH && code != DISMISS) return super.onTransact(code, data, reply, flags);
            data.enforceInterface(DESCRIPTOR);
            synchronized (RemoteUseWarning.this) {
                if (code == DISMISS) close();
                else if (!closed) {
                    observer = data.readStrongBinder();
                    death = RemoteUseWarning.this::close;
                    try { observer.linkToDeath(death, 0); }
                    catch (RemoteException dead) { close(); return true; }
                    deliverTouch();
                    System.out.println("DROIDMIRROR_WARNING_POSTED"); System.out.flush();
                }
            }
            return true;
        }
    };

    /** Fixed executable and package; no shell interpolation. */
    public static boolean launch() {
        return launch(null);
    }
    public static boolean launch(String computerName) {
        Process query = null, helper = null;
        boolean posted = false;
        try {
            query = new ProcessBuilder("/system/bin/pm", "path", "app.droidmirror.bluetooth")
                .redirectErrorStream(true).start();
            if (!query.waitFor(1500, TimeUnit.MILLISECONDS)) return false;
            String apk = null;
            try (BufferedReader lines = new BufferedReader(new InputStreamReader(query.getInputStream()))) {
                String line;
                while ((line = lines.readLine()) != null) if (line.startsWith("package:") && line.endsWith("/base.apk")) {
                    apk = line.substring(8); break;
                }
            }
            if (apk == null) return false;
            ProcessBuilder builder = new ProcessBuilder("/system/bin/app_process", "/", RemoteUseWarning.class.getName(), computerName == null ? "" : computerName)
                .redirectErrorStream(true);
            builder.environment().put("CLASSPATH", apk);
            helper = builder.start();
            long deadline = SystemClock.elapsedRealtime() + 2000;
            BufferedReader output = new BufferedReader(new InputStreamReader(helper.getInputStream()));
            while (SystemClock.elapsedRealtime() < deadline) {
                if (output.ready() && "DROIDMIRROR_WARNING_POSTED".equals(output.readLine())) { posted = true; return true; }
                if (!helper.isAlive()) return false;
                Thread.sleep(10);
            }
            return false;
        } catch (Exception failure) {
            if (failure instanceof InterruptedException) Thread.currentThread().interrupt();
            return false;
        } finally {
            if (query != null) query.destroy();
            // A successful helper owns its own lifetime, independently of the calling session.
            if (helper != null && !posted) helper.destroy();
        }
    }

    public static void main(String[] args) {
        Looper.prepare();
        RemoteUseWarning warning = new RemoteUseWarning();
        try {
            warning.input = new ProcessBuilder("/system/bin/getevent", "-lt").redirectErrorStream(true).start();
            Intent intent = new Intent().setComponent(new ComponentName("app.droidmirror.bluetooth",
                "app.droidmirror.bluetooth.RemoteUseWarningService"));
            Bundle extras = new Bundle(); extras.putBinder("touchMonitor", warning.controller); intent.putExtras(extras);
            if (args.length > 0) intent.putExtra("computerName", args[0]);
            ComponentName started = ServiceManager.getActivityManager().startForegroundService(intent);
            if (started == null || !"app.droidmirror.bluetooth".equals(started.getPackageName())) throw new IllegalStateException("Warning unavailable");
            Thread reader = new Thread(warning::readTouches, "RemoteUseTouch"); reader.setDaemon(true); reader.start();
            new android.os.Handler(warning.loop).postDelayed(() -> {
                synchronized (warning) { if (warning.observer == null) warning.close(); }
            }, 10000);
            Looper.loop();
        } catch (Exception failure) { android.util.Log.e("DroidMirrorWarning", "Warning unavailable", failure); }
        finally { warning.close(); }
    }

    private void readTouches() {
        try (BufferedReader lines = new BufferedReader(new InputStreamReader(input.getInputStream()))) {
            String line;
            while ((line = lines.readLine()) != null) if (RemoteUseTouch.isContact(line)) {
                synchronized (this) { if (!closed && touched == 0) { touched = SystemClock.elapsedRealtime(); deliverTouch(); } }
                input.destroy(); return;
            }
        } catch (java.io.IOException ignored) {}
        // If this device disallows raw input, the app retains the warning until unlock/tap/dismissal.
    }
    private void deliverTouch() {
        if (observer == null || touched == 0 || closed) return;
        Parcel data = Parcel.obtain();
        try { data.writeInterfaceToken(DESCRIPTOR); data.writeLong(touched); observer.transact(TOUCH, data, null, IBinder.FLAG_ONEWAY); }
        catch (RemoteException dead) { close(); }
        finally { data.recycle(); }
    }
    private synchronized void close() {
        if (closed) return;
        closed = true;
        if (input != null) input.destroy();
        if (observer != null && death != null) observer.unlinkToDeath(death, 0);
        loop.quitSafely();
    }
}
