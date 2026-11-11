package app.droidmirror.bluetooth;

public final class ApkInstallPolicy {
    public static final int LIMIT = 256 * 1024 * 1024;
    public static boolean allowed(long size) { return size > 0 && size < LIMIT; }
    public static boolean nameAllowed(String name) { return ClipboardFilePolicy.nameAllowed(name) && name.toLowerCase(java.util.Locale.ROOT).endsWith(".apk"); }
    private ApkInstallPolicy() {}
}
