package app.droidmirror.bluetooth;

import java.nio.charset.StandardCharsets;

/** Text only, bounded before encryption; never truncate someone’s clipboard. */
public final class ClipboardTextPolicy {
    public static final int MAX_BYTES = 4096;
    public static boolean allowed(String text) {
        if (text == null || text.isEmpty() || text.length() > MAX_BYTES) return false;
        int bytes = text.getBytes(StandardCharsets.UTF_8).length;
        if (bytes > MAX_BYTES) return false;
        // Account for JSON escaping plus AES-GCM/Base64 inside the 8192-byte frame limit.
        for (int index = 0; index < text.length(); index++) {
            char value = text.charAt(index);
            if (value < 32) bytes += 5;
            else if (value == '"' || value == '\\' || value == '/') bytes++;
            else if (value == '\u2028' || value == '\u2029') bytes += 3;
        }
        return bytes <= 5500;
    }
}
