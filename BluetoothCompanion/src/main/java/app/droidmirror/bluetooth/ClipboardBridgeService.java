package app.droidmirror.bluetooth;

import android.app.KeyguardManager;
import android.content.ClipData;
import android.content.ClipboardManager;
import android.content.Context;
import android.os.Binder;
import com.genymobile.scrcpy.FakeContext;

/** Separate Shizuku process: clipboard availability never owns a display lease. */
public final class ClipboardBridgeService extends IClipboardBridge.Stub {
    private volatile String status = "unavailable";
    private String reportedFailure;
    @Override public String getStatus() { return status; }
    private void failed(Throwable failure) {
        status = "unavailable";
        String kind = failure.getClass().getSimpleName();
        if (!kind.equals(reportedFailure)) android.util.Log.w("DroidMirrorClipboard", "Clipboard access failed: " + kind);
        reportedFailure = kind;
    }
    public ClipboardBridgeService() {}
    public ClipboardBridgeService(Context context) {}

    private ClipboardManager manager() throws Exception {
        PrivilegedCapture.initialize();
        return (ClipboardManager) FakeContext.get().getSystemService(Context.CLIPBOARD_SERVICE);
    }
    private boolean locked() {
        KeyguardManager keyguard = (KeyguardManager) FakeContext.get().getSystemService(Context.KEYGUARD_SERVICE);
        return keyguard == null || keyguard.isDeviceLocked();
    }
    @Override public synchronized String readText() {
        long identity = Binder.clearCallingIdentity();
        try {
            ClipboardManager clipboard = manager();
            if (locked()) { status = "locked"; return null; }
            if (clipboard == null) { status = "unavailable"; return null; }
            status = "ready"; reportedFailure = null;
            ClipData clip = clipboard.getPrimaryClip();
            if (clip == null || clip.getItemCount() != 1) return "";
            if (clip.getDescription().getExtras() != null
                && clip.getDescription().getExtras().getBoolean("android.content.extra.IS_SENSITIVE", false)) return null;
            CharSequence text = clip.getItemAt(0).getText();
            String value = text == null ? null : text.toString();
            return ClipboardTextPolicy.allowed(value) ? value : "";
        } catch (Exception | LinkageError failure) { failed(failure); return null; }
        finally { Binder.restoreCallingIdentity(identity); }
    }
    @Override public synchronized boolean writeText(String text) {
        if (!ClipboardTextPolicy.allowed(text)) return false;
        long identity = Binder.clearCallingIdentity();
        try {
            ClipboardManager clipboard = manager();
            if (locked()) { status = "locked"; return false; }
            if (clipboard == null) { status = "unavailable"; return false; }
            clipboard.setPrimaryClip(ClipData.newPlainText("DroidMirror", text));
            status = "ready"; reportedFailure = null;
            return true;
        } catch (Exception | LinkageError failure) { failed(failure); return false; }
        finally { Binder.restoreCallingIdentity(identity); }
    }
    @Override public void destroy() { System.exit(0); }
}
