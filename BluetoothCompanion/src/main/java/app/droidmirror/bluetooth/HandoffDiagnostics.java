package app.droidmirror.bluetooth;

import java.util.Set;
import java.util.TreeSet;
import java.util.regex.Matcher;
import java.util.regex.Pattern;

/** Extract identity only; never persist task titles, intents, extras or URLs. */
public final class HandoffDiagnostics {
    private static final Pattern PACKAGE = Pattern.compile(
            "(?:packageName|package|mPackageName)\\s*[=:]\\s*['\\\"]?([A-Za-z0-9_]+(?:\\.[A-Za-z0-9_]+)+)");
    private static final Pattern TASK = Pattern.compile(
            "(?m)^\\s*Task \\d+:\\s*([A-Za-z0-9_]+(?:\\.[A-Za-z0-9_]+)+)\\s*$");
    private HandoffDiagnostics() {}
    public static Set<String> packages(String listing) {
        Set<String> result = new TreeSet<>();
        Matcher matcher = PACKAGE.matcher(listing);
        while (matcher.find()) result.add(matcher.group(1));
        matcher = TASK.matcher(listing);
        while (matcher.find()) result.add(matcher.group(1));
        return result;
    }
}
