package app.droidmirror.bluetooth;

import android.app.WallpaperManager;
import android.graphics.Bitmap;
import android.graphics.BitmapFactory;
import android.os.ParcelFileDescriptor;
import android.util.Base64;
import com.genymobile.scrcpy.FakeContext;
import org.json.JSONObject;
import java.io.ByteArrayOutputStream;

/** Runs as the authorized Shizuku shell service, never the unprivileged app. */
final class PhoneAppearance {
    static byte[] read() {
        JSONObject result = new JSONObject();
        try {
            Process dump = new ProcessBuilder("/system/bin/dumpsys", "display").start();
            // Drain concurrently with a deadline; dumpsys output can exceed a pipe buffer.
            Thread reader = new Thread(() -> {
                try (java.io.BufferedReader lines = new java.io.BufferedReader(new java.io.InputStreamReader(dump.getInputStream()))) {
                    String line;
                    while ((line = lines.readLine()) != null) {
                        if (line.contains("DisplayDeviceInfo{") && line.contains("type INTERNAL") && line.length() < 12000) {
                            synchronized (result) { result.put("displayDump", line); }
                            break;
                        }
                    }
                } catch (Exception ignored) {}
            }, "PhoneGeometry");
            reader.start();
            reader.join(2000);
            dump.destroy();
            reader.join(200);
        } catch (Exception ignored) {}
        try {
            PrivilegedCapture.initialize();
            String name = android.provider.Settings.Global.getString(FakeContext.get().getContentResolver(), "device_name");
            if (name != null && !name.isBlank()) result.put("deviceName", name);
            // getWallpaperFile fails explicitly when access is denied; getDrawable can
            // silently return Android's default wallpaper on recent releases.
            WallpaperManager wallpapers = WallpaperManager.getInstance(FakeContext.get());
            // getInstance delegates to FakeContext's base system context. Bind the
            // manager to shell attribution, as FakeContext does for clipboard and
            // activity services, rather than making requests as package "android".
            java.lang.reflect.Field context = WallpaperManager.class.getDeclaredField("mContext");
            context.setAccessible(true);
            context.set(wallpapers, FakeContext.get());
            android.app.WallpaperInfo live = wallpapers.getWallpaperInfo();
            Bitmap bitmap;
            if (live != null) {
                // A live wallpaper's image file may still contain the previous
                // static wallpaper. Read the wallpaper layer, never the display.
                bitmap = null;
                for (int attempt = 0; attempt < 5 && bitmap == null; ++attempt) {
                    if (attempt != 0) Thread.sleep(200);
                    bitmap = snapshotWallpaper();
                }
                if (bitmap == null) throw new java.io.IOException("Live wallpaper layer is not visible; retaining last captured preview");
                android.util.Log.i("DroidMirrorAppearance", "Captured live wallpaper layer: " + live.getComponent());
            } else {
                try (ParcelFileDescriptor file = wallpapers.getWallpaperFile(WallpaperManager.FLAG_SYSTEM)) {
                    if (file == null) throw new java.io.IOException("No readable static wallpaper file");
                    BitmapFactory.Options bounds = new BitmapFactory.Options();
                    bounds.inJustDecodeBounds = true;
                    BitmapFactory.decodeFileDescriptor(file.getFileDescriptor(), null, bounds);
                    BitmapFactory.Options options = new BitmapFactory.Options();
                    options.inSampleSize = 1;
                    while (Math.max(bounds.outWidth, bounds.outHeight) / options.inSampleSize > 192) options.inSampleSize *= 2;
                    bitmap = BitmapFactory.decodeFileDescriptor(file.getFileDescriptor(), null, options);
                }
            }
            if (bitmap == null) throw new java.io.IOException("Wallpaper could not be decoded");
            byte[] preview = encodePreview(bitmap);
            if (preview != null) {
                result.put("wallpaper", Base64.encodeToString(preview, Base64.NO_WRAP));
                android.util.Log.i("DroidMirrorAppearance", "Fresh shell wallpaper: " + preview.length + " bytes");
            } else android.util.Log.w("DroidMirrorAppearance", "Wallpaper preview exceeds transfer limit");
        } catch (Exception | LinkageError unavailable) {
            android.util.Log.d("DroidMirrorAppearance", "Wallpaper unavailable", unavailable);
        }
        synchronized (result) {
            byte[] bytes = (result.toString() + "\n").getBytes(java.nio.charset.StandardCharsets.UTF_8);
            return bytes.length <= BluetoothWire.MAX_CHUNK ? bytes : null;
        }
    }
    private static Bitmap snapshotWallpaper() {
        try {
            android.os.IBinder binder = (android.os.IBinder) Class.forName("android.os.ServiceManager")
                .getMethod("getService", String.class).invoke(null, "window");
            Class<?> type = Class.forName("android.view.IWindowManager");
            Object windows = Class.forName("android.view.IWindowManager$Stub")
                .getMethod("asInterface", android.os.IBinder.class).invoke(null, binder);
            return (Bitmap) type.getMethod("screenshotWallpaper").invoke(windows);
        } catch (Exception | LinkageError unavailable) {
            android.util.Log.d("DroidMirrorAppearance", "Wallpaper layer snapshot unavailable", unavailable);
            return null;
        }
    }

    // Owns and releases its input, including hardware-backed wallpaper snapshots.
    static byte[] encodePreview(Bitmap bitmap) {
        try {
            if (bitmap.getConfig() == Bitmap.Config.HARDWARE) {
                Bitmap software = bitmap.copy(Bitmap.Config.ARGB_8888, false);
                bitmap.recycle();
                bitmap = software;
                if (bitmap == null) return null;
            }
            int longest = Math.max(bitmap.getWidth(), bitmap.getHeight());
            if (longest > 192) {
                Bitmap scaled = Bitmap.createScaledBitmap(bitmap,
                    Math.max(1, Math.round(bitmap.getWidth() * 192f / longest)),
                    Math.max(1, Math.round(bitmap.getHeight() * 192f / longest)), true);
                if (scaled != bitmap) bitmap.recycle();
                bitmap = scaled;
            }
            ByteArrayOutputStream bytes = new ByteArrayOutputStream();
            for (int quality : new int[] {55, 35, 15}) {
                bytes.reset();
                if (bitmap.compress(Bitmap.CompressFormat.JPEG, quality, bytes) && bytes.size() <= 10000)
                    return bytes.toByteArray();
            }
            return null;
        } finally {
            if (bitmap != null && !bitmap.isRecycled()) bitmap.recycle();
        }
    }

}
