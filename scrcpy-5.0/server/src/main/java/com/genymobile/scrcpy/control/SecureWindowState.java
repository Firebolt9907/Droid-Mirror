package com.genymobile.scrcpy.control;

import java.io.IOException;
import java.io.Reader;
import java.util.regex.Matcher;
import java.util.regex.Pattern;

/** WindowManager metadata only; no screenshots or pixel inspection. */
public final class SecureWindowState {
    public static final int CLEAR = 0;
    public static final int SECURE = 1;
    public static final int UNKNOWN = 2;
    private static final int MAX_CHARS = 2 * 1024 * 1024;
    private static final Pattern WINDOW = Pattern.compile("(?m)^  Window #\\d+ Window\\{");
    private static final Pattern DISPLAY = Pattern.compile("\\bmDisplayId=(\\d+)\\b");
    private static final Pattern FLAGS = Pattern.compile("(?:^|\\s)fl=([^\\r\\n}]*)");
    private static final Pattern SECURE_FLAG = Pattern.compile("(?:^|[\\s|])(?:FLAG_)?SECURE(?:$|[\\s|])");

    private SecureWindowState() { }

    public static int read(Reader reader, int displayId) throws IOException {
        StringBuilder dump = new StringBuilder();
        char[] buffer = new char[4096];
        int count;
        while ((count = reader.read(buffer)) != -1) {
            if (dump.length() + count > MAX_CHARS) return UNKNOWN;
            dump.append(buffer, 0, count);
        }
        return parse(dump.toString(), displayId);
    }

    public static int parse(String dump, int displayId) {
        if (displayId < 0 || dump.length() > MAX_CHARS || !dump.contains("WINDOW MANAGER WINDOWS")
                || dump.contains("DUMP TIMEOUT") || dump.contains("timed out")) return UNKNOWN;
        Matcher windows = WINDOW.matcher(dump);
        if (!windows.find()) return UNKNOWN;
        int start = windows.start();
        boolean foundDisplay = false;
        boolean incomplete = false;
        boolean secure = false;
        do {
            boolean next = windows.find();
            int end = next ? windows.start() : dump.length();
            String window = dump.substring(start, end);
            Matcher display = DISPLAY.matcher(window);
            if (!display.find()) {
                incomplete = true;
            } else if (Integer.toString(displayId).equals(display.group(1))) {
                foundDisplay = true;
                // All three must agree. Hidden/background windows must never trigger the overlay.
                if (!window.contains("isVisible=") || !window.contains("isOnScreen=") || !window.contains("mHasSurface=")) {
                    incomplete = true;
                } else if (window.contains("isVisible=true") && window.contains("isOnScreen=true")
                        && window.contains("mHasSurface=true") && !window.contains("mObscured=true")) {
                    Matcher flags = FLAGS.matcher(window);
                    if (!flags.find()) {
                        incomplete = true;
                    } else {
                        String value = flags.group(1).trim();
                        if (SECURE_FLAG.matcher(value).find()) {
                            secure = true;
                        } else {
                            String first = value.split("\\s+", 2)[0];
                            if (first.matches("(?:0[xX])?[0-9a-fA-F]+")) {
                                try {
                                    secure |= (Long.parseLong(first.replaceFirst("^0[xX]", ""), 16) & 0x2000) != 0;
                                } catch (NumberFormatException invalid) {
                                    incomplete = true;
                                }
                            }
                        }
                    }
                }
            }
            if (!next) break;
            start = end;
        } while (true);
        return incomplete || !foundDisplay ? UNKNOWN : secure ? SECURE : CLEAR;
    }
}
