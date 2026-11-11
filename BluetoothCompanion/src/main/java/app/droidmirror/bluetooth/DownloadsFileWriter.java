package app.droidmirror.bluetooth;

import android.content.ContentValues;
import android.content.Context;
import android.net.Uri;
import android.os.Build;
import android.provider.MediaStore;
import java.io.OutputStream;

/** Publishes only complete files, using MediaStore's collision-safe Downloads naming. */
final class DownloadsFileWriter {
    static boolean save(Context context, String name, byte[] data) {
        if (Build.VERSION.SDK_INT < 29 || !ClipboardFilePolicy.nameAllowed(name)) return false;
        Uri item = null;
        boolean published = false;
        try {
            ContentValues values = new ContentValues();
            values.put(MediaStore.MediaColumns.DISPLAY_NAME, name);
            values.put(MediaStore.MediaColumns.MIME_TYPE, "application/octet-stream");
            values.put(MediaStore.MediaColumns.RELATIVE_PATH, "Download/");
            values.put(MediaStore.MediaColumns.IS_PENDING, 1);
            item = context.getContentResolver().insert(MediaStore.Downloads.EXTERNAL_CONTENT_URI, values);
            if (item == null) return false;
            try (OutputStream output = context.getContentResolver().openOutputStream(item, "w")) {
                if (output == null) return false;
                output.write(data);
            }
            values.clear();
            values.put(MediaStore.MediaColumns.IS_PENDING, 0);
            published = context.getContentResolver().update(item, values, null, null) == 1;
            return published;
        } catch (Exception failure) { return false; }
        finally {
            if (item != null && !published) {
                try { context.getContentResolver().delete(item, null, null); } catch (Exception ignored) {}
            }
        }
    }
}
