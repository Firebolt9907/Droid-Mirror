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
            try (ParcelFileDescriptor file = WallpaperManager.getInstance(FakeContext.get())
                    .getWallpaperFile(WallpaperManager.FLAG_SYSTEM)) {
                if (file != null) {
                    BitmapFactory.Options bounds = new BitmapFactory.Options();
                    bounds.inJustDecodeBounds = true;
                    BitmapFactory.decodeFileDescriptor(file.getFileDescriptor(), null, bounds);
                    BitmapFactory.Options options = new BitmapFactory.Options();
                    options.inSampleSize = 1;
                    while (Math.max(bounds.outWidth, bounds.outHeight) / options.inSampleSize > 192) options.inSampleSize *= 2;
                    Bitmap bitmap = BitmapFactory.decodeFileDescriptor(file.getFileDescriptor(), null, options);
                    if (bitmap != null) {
                        ByteArrayOutputStream bytes = new ByteArrayOutputStream();
                        bitmap.compress(Bitmap.CompressFormat.JPEG, 55, bytes);
                        bitmap.recycle();
                        if (bytes.size() <= 10000) result.put("wallpaper", Base64.encodeToString(bytes.toByteArray(), Base64.NO_WRAP));
                    }
                }
            }
        } catch (Exception | LinkageError unavailable) {
            android.util.Log.d("DroidMirrorAppearance", "Wallpaper unavailable", unavailable);
        }
        synchronized (result) {
            byte[] bytes = (result.toString() + "\n").getBytes(java.nio.charset.StandardCharsets.UTF_8);
            return bytes.length <= BluetoothWire.MAX_CHUNK ? bytes : null;
        }
    }
}
