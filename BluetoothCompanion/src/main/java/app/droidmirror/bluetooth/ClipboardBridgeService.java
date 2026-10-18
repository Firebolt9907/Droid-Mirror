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
    private byte[] fileSnapshot;
    private String snapshotUri, snapshotToken;
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
            if (locked()) { fileSnapshot = null; status = "locked"; return null; }
            if (clipboard == null) { fileSnapshot = null; status = "unavailable"; return null; }
            status = "ready"; reportedFailure = null;
            ClipData clip = clipboard.getPrimaryClip();
            if (clip == null || clip.getItemCount() != 1) { fileSnapshot = null; return ""; }
            if (!Long.toString(clip.getDescription().getTimestamp()).equals(snapshotToken)) fileSnapshot = null;
            if (clip.getDescription().getExtras() != null
                && clip.getDescription().getExtras().getBoolean("android.content.extra.IS_SENSITIVE", false)) { fileSnapshot = null; return null; }
            if (clip.getItemAt(0).getUri() != null) return "";
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
    private ClipData readableClip() throws Exception {
        ClipboardManager clipboard = manager();
        if (locked() || clipboard == null) return null;
        ClipData clip = clipboard.getPrimaryClip();
        if (clip != null && clip.getDescription().getExtras() != null
                && clip.getDescription().getExtras().getBoolean("android.content.extra.IS_SENSITIVE", false)) { fileSnapshot = null; return null; }
        return clip;
    }
    @Override public synchronized String readToken() {
        long identity = Binder.clearCallingIdentity();
        try {
            ClipData clip = readableClip();
            String token = locked() || manager() == null ? null
                : clip == null ? (manager().hasPrimaryClip() ? null : "empty")
                : Long.toString(clip.getDescription().getTimestamp());
            if (token == null || !token.equals(snapshotToken)) fileSnapshot = null;
            return token;
        } catch (Exception | LinkageError failure) { failed(failure); return null; }
        finally { Binder.restoreCallingIdentity(identity); }
    }
    @Override public synchronized String readFileInfo() {
        long identity = Binder.clearCallingIdentity();
        try {
            ClipData clip = readableClip();
            if (clip == null || clip.getItemCount() != 1) return null;
            android.net.Uri uri = clip.getItemAt(0).getUri();
            if (uri == null || !"content".equals(uri.getScheme())) return null;
            try (ClipboardResolver resolver = new ClipboardResolver();
                    android.database.Cursor cursor = resolver.query(uri,
                    new String[]{android.provider.OpenableColumns.DISPLAY_NAME, android.provider.OpenableColumns.SIZE}, null, null, null)) {
                if (cursor == null || !cursor.moveToFirst() || cursor.isNull(1)) return null;
                String name = cursor.getString(0); long size = cursor.getLong(1);
                if (!ClipboardFilePolicy.nameAllowed(name) || !ClipboardFilePolicy.allowed(size)) return null;
                return new org.json.JSONObject().put("uri", uri.toString()).put("name", name).put("size", size).toString();
            }
        } catch (Exception | LinkageError failure) { return null; }
        finally { Binder.restoreCallingIdentity(identity); }
    }
    @Override public synchronized byte[] readFileChunk(String value, int offset) {
        if (offset < 0 || offset >= ClipboardFilePolicy.LIMIT) return null;
        long identity = Binder.clearCallingIdentity();
        try {
            ClipData clip = readableClip();
            android.net.Uri uri = android.net.Uri.parse(value);
            if (clip == null || clip.getItemCount() != 1 || !uri.equals(clip.getItemAt(0).getUri())
                    || !"content".equals(uri.getScheme())) { fileSnapshot = null; return null; }
            String token = Long.toString(clip.getDescription().getTimestamp());
            if (offset == 0) {
                fileSnapshot = null;
                try (ClipboardResolver resolver = new ClipboardResolver();
                        java.io.InputStream input = resolver.openInputStream(uri)) {
                    if (input == null) return null;
                    java.io.ByteArrayOutputStream snapshot = new java.io.ByteArrayOutputStream();
                    byte[] buffer = new byte[65_536];
                    while (snapshot.size() < ClipboardFilePolicy.LIMIT) {
                        int count = input.read(buffer, 0, Math.min(buffer.length, ClipboardFilePolicy.LIMIT - snapshot.size()));
                        if (count == -1) break;
                        if (count == 0 || !token.equals(readToken())) return null;
                        snapshot.write(buffer, 0, count);
                    }
                    if (!ClipboardFilePolicy.allowed(snapshot.size())) return null;
                    fileSnapshot = snapshot.toByteArray(); snapshotUri = value; snapshotToken = token;
                }
            }
            if (fileSnapshot == null || !value.equals(snapshotUri) || !token.equals(snapshotToken)
                    || offset > fileSnapshot.length) { fileSnapshot = null; return null; }
            byte[] result = java.util.Arrays.copyOfRange(fileSnapshot, offset, Math.min(fileSnapshot.length, offset + ClipboardFilePolicy.CHUNK));
            if (result.length == 0) fileSnapshot = null;
            return result;
        } catch (Exception | LinkageError failure) { fileSnapshot = null; return null; }
        finally { Binder.restoreCallingIdentity(identity); }
    }
    @Override public synchronized boolean writeFile(String value, String expectedToken) {
        long identity = Binder.clearCallingIdentity();
        try {
            if (expectedToken == null || !expectedToken.equals(readToken())) return false;
            android.net.Uri uri = android.net.Uri.parse(value);
            if (!"content".equals(uri.getScheme()) || !"app.droidmirror.bluetooth.clipboard.files".equals(uri.getAuthority())) return false;
            try (ClipboardResolver resolver = new ClipboardResolver()) {
                manager().setPrimaryClip(ClipData.newUri(resolver, "DroidMirror", uri));
            }
            return true;
        } catch (Exception | LinkageError failure) { failed(failure); return false; }
        finally { Binder.restoreCallingIdentity(identity); }
    }
    @Override public void destroy() { System.exit(0); }
}
