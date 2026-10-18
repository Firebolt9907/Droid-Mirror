package app.droidmirror.bluetooth;

import java.net.URI;

/** App-specific rules stay here; unsupported or ambiguous metadata has no result. */
public final class TaskUrlResolver {
    public static String currentUrl(String assistUrl, String intentData, String resolvedIntentUrl) {
        if (webUrl(assistUrl)) return assistUrl;
        // A generic launch URL can be stale after browser navigation or a tab switch.
        // Retain only the validated Docs content-ID adapter as an intent fallback.
        return intentData != null && intentData.startsWith("content://uniqueId/")
                && webUrl(resolvedIntentUrl) ? resolvedIntentUrl : null;
    }
    public static String resolve(String pkg, String activity, String action, String data) {
        if (!"android.intent.action.VIEW".equals(action) || data == null) return null;
        if (webUrl(data)) return data;
        if (!"com.google.android.apps.docs.editors.docs".equals(pkg)
                || !"com.google.android.apps.docs.editors.kix.KixEditorActivity".equals(activity)) return null;
        try {
            URI uri = new URI(data);
            String path = uri.getRawPath();
            if (!"content".equals(uri.getScheme()) || !"uniqueId".equals(uri.getRawAuthority())
                    || uri.getRawQuery() != null || uri.getRawFragment() != null
                    || path == null || !path.matches("/[A-Za-z0-9_-]{10,256}")) return null;
            return "https://docs.google.com/document/d" + path + "/edit";
        } catch (Exception ignored) { return null; }
    }

    public static boolean webUrl(String value) {
        if (value == null || value.length() > 2048 || value.chars().anyMatch(c -> c <= 32 || c == 127)) return false;
        try {
            URI uri = new URI(value);
            return ("https".equalsIgnoreCase(uri.getScheme()) || "http".equalsIgnoreCase(uri.getScheme()))
                    && uri.getHost() != null && !uri.getHost().isEmpty() && uri.getRawUserInfo() == null;
        } catch (Exception ignored) { return false; }
    }
}
