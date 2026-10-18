package app.droidmirror.bluetooth;

import android.content.ContentProvider;
import android.content.ContentValues;
import android.database.Cursor;
import android.database.MatrixCursor;
import android.net.Uri;
import android.os.ParcelFileDescriptor;
import android.provider.OpenableColumns;
import java.io.File;
import java.io.FileNotFoundException;
import java.io.IOException;

/** Only completed clipboard files, read-only and protected by per-URI grants. */
public final class ClipboardFileProvider extends ContentProvider {
    @Override public boolean onCreate() { return true; }
    static File root(android.content.Context context) { return new File(context.getCacheDir(), "clipboard-files"); }
    private File file(Uri uri) throws FileNotFoundException {
        java.util.List<String> parts = uri.getPathSegments();
        if (parts.size() != 2 || !parts.get(0).matches("[a-f0-9-]{36}")
                || !ClipboardFilePolicy.nameAllowed(parts.get(1))) throw new FileNotFoundException();
        File result = new File(new File(root(getContext()), parts.get(0)), parts.get(1));
        try {
            if (!result.getCanonicalPath().startsWith(root(getContext()).getCanonicalPath() + File.separator)
                    || !result.isFile()) throw new FileNotFoundException();
        } catch (IOException failure) { throw new FileNotFoundException(); }
        return result;
    }
    @Override public ParcelFileDescriptor openFile(Uri uri, String mode) throws FileNotFoundException {
        if (!"r".equals(mode)) throw new FileNotFoundException("Read only");
        return ParcelFileDescriptor.open(file(uri), ParcelFileDescriptor.MODE_READ_ONLY);
    }
    @Override public String getType(Uri uri) {
        String extension = android.webkit.MimeTypeMap.getFileExtensionFromUrl(uri.toString());
        String type = android.webkit.MimeTypeMap.getSingleton().getMimeTypeFromExtension(extension.toLowerCase(java.util.Locale.ROOT));
        return type == null ? "application/octet-stream" : type;
    }
    @Override public Cursor query(Uri uri, String[] projection, String selection, String[] args, String sort) {
        try {
            File file = file(uri);
            String[] columns = projection == null ? new String[]{OpenableColumns.DISPLAY_NAME, OpenableColumns.SIZE} : projection;
            MatrixCursor cursor = new MatrixCursor(columns);
            Object[] row = new Object[columns.length];
            for (int i = 0; i < columns.length; i++) {
                if (OpenableColumns.DISPLAY_NAME.equals(columns[i])) row[i] = file.getName();
                if (OpenableColumns.SIZE.equals(columns[i])) row[i] = file.length();
            }
            cursor.addRow(row); return cursor;
        } catch (FileNotFoundException failure) { return null; }
    }
    @Override public Uri insert(Uri uri, ContentValues values) { throw new UnsupportedOperationException(); }
    @Override public int delete(Uri uri, String selection, String[] args) { throw new UnsupportedOperationException(); }
    @Override public int update(Uri uri, ContentValues values, String selection, String[] args) { throw new UnsupportedOperationException(); }
}
