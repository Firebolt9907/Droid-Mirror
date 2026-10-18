package app.droidmirror.bluetooth;
final class ClipboardFileProvider {
    static java.io.File root(android.content.Context context) { return new java.io.File(context.getCacheDir(), "clipboard-files"); }
}
