package app.droidmirror.bluetooth;

import android.app.KeyguardManager;
import android.content.ClipData;
import android.content.ClipboardManager;
import android.content.Context;
import android.os.Binder;
import android.os.Build;
import android.os.Looper;
import com.genymobile.scrcpy.FakeContext;

/** Shizuku bridge running in the shell UID. Keeps file snapshots only in memory. */
public final class ClipboardBridgeService extends IClipboardBridge.Stub {
    private String status = "ready";
    private String reportedFailure;
    private byte[] fileSnapshot;
    private String snapshotUri;
    private String snapshotToken;

    private static void ensureLooper() {
        if (Looper.myLooper() == null) {
            try {
                Looper.prepare();
            } catch (Throwable ignored) {}
        }
    }

    private void failed(Throwable failure) {
        String kind = failure.getClass().getSimpleName();
        status = "unavailable";
        android.util.Log.w("DroidMirrorClipboard", "Clipboard access failed: " + kind, failure);
        reportedFailure = kind;
    }
    public ClipboardBridgeService() {
        ensureLooper();
    }
    public ClipboardBridgeService(Context context) {
        ensureLooper();
    }

    private ClipboardManager manager() throws Exception {
        ensureLooper();
        return (ClipboardManager) FakeContext.get().getSystemService(Context.CLIPBOARD_SERVICE);
    }
    private boolean locked() {
        try {
            ensureLooper();
            KeyguardManager keyguard = (KeyguardManager) FakeContext.get().getSystemService(Context.KEYGUARD_SERVICE);
            if (keyguard != null) return keyguard.isDeviceLocked();
        } catch (Throwable ignored) {}
        try {
            android.os.IBinder binder = (android.os.IBinder) Class.forName("android.os.ServiceManager")
                .getDeclaredMethod("getService", String.class).invoke(null, "window");
            if (binder != null) {
                Object window = Class.forName("android.view.IWindowManager$Stub")
                    .getMethod("asInterface", android.os.IBinder.class).invoke(null, binder);
                if (window != null) {
                    return (boolean) window.getClass().getMethod("isKeyguardLocked").invoke(window);
                }
            }
        } catch (Throwable ignored) {}
        return false;
    }

    @Override public synchronized String getStatus() { return status; }
    @Override public synchronized String readText() {
        long identity = Binder.clearCallingIdentity();
        try {
            ensureLooper();
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
    @Override public synchronized boolean writeText(String value) {
        if (!ClipboardTextPolicy.allowed(value)) return false;
        long identity = Binder.clearCallingIdentity();
        try {
            ensureLooper();
            ClipboardManager clipboard = manager();
            if (locked() || clipboard == null) return false;
            fileSnapshot = null;
            clipboard.setPrimaryClip(ClipData.newPlainText("DroidMirror", value));
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
            ensureLooper();
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
            ensureLooper();
            ClipData clip = readableClip();
            if (clip == null || clip.getItemCount() == 0) return null;
            android.net.Uri uri = null;
            for (int i = 0; i < clip.getItemCount(); i++) {
                android.net.Uri u = clip.getItemAt(i).getUri();
                if (u != null && "content".equals(u.getScheme())) {
                    uri = u;
                    break;
                }
            }
            if (uri == null) return null;
            try (ClipboardResolver resolver = new ClipboardResolver()) {
                String name = null;
                long size = -1;
                try (android.database.Cursor cursor = resolver.query(uri,
                        new String[]{android.provider.OpenableColumns.DISPLAY_NAME, android.provider.OpenableColumns.SIZE}, null, null, null)) {
                    if (cursor != null && cursor.moveToFirst()) {
                        if (!cursor.isNull(0)) name = cursor.getString(0);
                        if (!cursor.isNull(1)) size = cursor.getLong(1);
                    }
                } catch (Exception ignored) {}
                if (name == null || !ClipboardFilePolicy.nameAllowed(name)) {
                    String mime = resolver.getType(uri);
                    if (mime != null && mime.startsWith("image/")) {
                        String ext = android.webkit.MimeTypeMap.getSingleton().getExtensionFromMimeType(mime);
                        name = "image." + (ext != null ? ext : "png");
                    } else {
                        String segment = uri.getLastPathSegment();
                        if (segment != null) {
                            int lastSlash = Math.max(segment.lastIndexOf("/"), segment.lastIndexOf("\\"));
                            if (lastSlash >= 0) segment = segment.substring(lastSlash + 1);
                            if (ClipboardFilePolicy.nameAllowed(segment)) name = segment;
                        }
                    }
                }
                if (name == null || !ClipboardFilePolicy.nameAllowed(name)) {
                    name = "clipboard_image.png";
                }
                if (size <= 0) {
                    try (android.content.res.AssetFileDescriptor afd = resolver.openAssetFileDescriptor(uri, "r")) {
                        if (afd != null) size = afd.getLength();
                    } catch (Exception ignored) {}
                }
                if (size <= 0) {
                    try (java.io.InputStream in = resolver.openInputStream(uri)) {
                        if (in != null) {
                            byte[] buf = new byte[16_384];
                            long total = 0;
                            int r;
                            while ((r = in.read(buf)) != -1) {
                                total += r;
                                if (total > ClipboardFilePolicy.LIMIT) break;
                            }
                            size = total;
                        }
                    } catch (Exception ignored) {}
                }
                android.util.Log.i("DroidMirrorClipboard", "readFileInfo resolved: name=" + name + " size=" + size + " uri=" + uri);
                if (!ClipboardFilePolicy.nameAllowed(name) || !ClipboardFilePolicy.allowed(size)) return null;
                return new org.json.JSONObject().put("uri", uri.toString()).put("name", name).put("size", size).toString();
            }
        } catch (Exception | LinkageError failure) {
            android.util.Log.e("DroidMirrorClipboard", "readFileInfo exception", failure);
            return null;
        }
        finally { Binder.restoreCallingIdentity(identity); }
    }
    @Override public synchronized byte[] readFileChunk(String value, int offset) {
        if (offset < 0 || offset >= ClipboardFilePolicy.LIMIT) return null;
        long identity = Binder.clearCallingIdentity();
        try {
            ensureLooper();
            ClipData clip = readableClip();
            android.net.Uri uri = android.net.Uri.parse(value);
            if (clip == null || !"content".equals(uri.getScheme())) { fileSnapshot = null; return null; }
            boolean found = false;
            for (int i = 0; i < clip.getItemCount(); i++) {
                android.net.Uri itemUri = clip.getItemAt(i).getUri();
                if (itemUri != null && (uri.equals(itemUri) || (uri.getAuthority() != null && uri.getAuthority().equals(itemUri.getAuthority()) && uri.getPath() != null && uri.getPath().equals(itemUri.getPath())))) {
                    found = true;
                    break;
                }
            }
            if (!found) { fileSnapshot = null; return null; }
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
                        if (count == 0) return null;
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
        } catch (Exception | LinkageError failure) {
            android.util.Log.e("DroidMirrorClipboard", "readFileChunk exception", failure);
            fileSnapshot = null; return null;
        }
        finally { Binder.restoreCallingIdentity(identity); }
    }
    @Override public synchronized boolean writeFile(String value, String expectedToken) {
        long identity = Binder.clearCallingIdentity();
        try {
            ensureLooper();
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
