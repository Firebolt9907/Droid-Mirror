package app.droidmirror.bluetooth;

/** Decimal MB, strictly less than the limit. Same wire policy as the Mac. */
public final class ClipboardFilePolicy {
    public static final int LIMIT = 5_000_000;
    public static final int CHUNK = 3072;
    public static boolean allowed(long size) { return size >= 0 && size < LIMIT; }
    public static boolean nameAllowed(String name) {
        return name != null && !name.isEmpty() && !name.equals(".") && !name.equals("..")
            && name.getBytes(java.nio.charset.StandardCharsets.UTF_8).length <= 240
            && name.chars().noneMatch(c -> c < 32 || c == 127 || c == '/' || c == '\\' || c == ':');
    }
}
