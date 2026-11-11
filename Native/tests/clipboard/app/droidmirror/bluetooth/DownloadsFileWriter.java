package app.droidmirror.bluetooth;
/** JVM-only Downloads sink; production uses MediaStore. */
final class DownloadsFileWriter {
    static String name;
    static byte[] data;
    static boolean succeeds = true;
    static boolean save(android.content.Context context, String filename, byte[] bytes) {
        name = filename; data = bytes; return succeeds;
    }
}
