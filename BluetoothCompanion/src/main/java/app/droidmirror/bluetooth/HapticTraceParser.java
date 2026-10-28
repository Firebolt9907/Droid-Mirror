package app.droidmirror.bluetooth;

import java.util.HashMap;
import java.util.Map;
import java.util.regex.Matcher;
import java.util.regex.Pattern;

/** Only service request entry points count; app wrappers and nested calls do not. */
final class HapticTraceParser {
    private static final Pattern PREFIX = Pattern.compile("-(\\d+)\\s+\\(.*?([0-9]+\\.[0-9]+): tracing_mark_write: (.*)$");
    private static final class Stack { int depth, requestDepth; }
    private final Map<Integer, Stack> threads = new HashMap<>();
    private final int server;
    HapticTraceParser(int systemServerPid) { server = systemServerPid; }

    boolean accept(String line, double elapsedSeconds) {
        if (line.contains("LOST") && line.contains("EVENTS")) throw new IllegalStateException("Haptic trace lost events");
        Matcher m = PREFIX.matcher(line);
        if (!m.find()) return false;
        String marker = m.group(3);
        boolean begin = marker.startsWith("B|" + server + "|");
        boolean end = marker.equals("E|" + server);
        if (!begin && !end) return false;
        int tid = Integer.parseInt(m.group(1));
        Stack stack = threads.get(tid);
        if (end) {
            if (stack != null) {
                if (stack.requestDepth == stack.depth) stack.requestDepth = 0;
                if (--stack.depth <= 0) threads.remove(tid);
            }
            return false;
        }
        if (stack == null) {
            if (threads.size() >= 1024) throw new IllegalStateException("Haptic trace nesting unavailable");
            stack = new Stack(); threads.put(tid, stack);
        }
        stack.depth++;
        if (stack.depth > 256) throw new IllegalStateException("Haptic trace nesting overflow");
        String name = marker.substring(marker.indexOf('|', 2) + 1);
        boolean request = name.equals("vibrate") || name.equals("performHapticFeedback")
            || name.equals("performHapticFeedbackForInputDevice");
        if (!request || stack.requestDepth != 0) return false;
        stack.requestDepth = stack.depth;
        double age = elapsedSeconds - Double.parseDouble(m.group(2));
        return age >= -0.05 && age <= 0.2;
    }
}
