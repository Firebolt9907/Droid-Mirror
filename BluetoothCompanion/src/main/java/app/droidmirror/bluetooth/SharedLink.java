package app.droidmirror.bluetooth;

import java.util.regex.Matcher;
import java.util.regex.Pattern;

/** A title plus one web link is common in Android shares. Reject ambiguous input. */
public final class SharedLink {
    public static String extract(String text) {
        if (text == null || text.length() > 8192) return null;
        String trimmed = text.trim();
        if (TaskUrlResolver.webUrl(trimmed)) return trimmed;
        Matcher matcher = Pattern.compile("https?://[^\\s<>\"]+", Pattern.CASE_INSENSITIVE).matcher(trimmed);
        String result = null;
        while (matcher.find()) {
            if (result != null) return null;
            String candidate = matcher.group();
            if (!TaskUrlResolver.webUrl(candidate)) return null;
            result = candidate;
        }
        return result;
    }
}
