package app.droidmirror.bluetooth;

import java.util.ArrayList;
import java.util.List;

/** Select direct multitouch screens, preserving mice, touchpads and the physical power key. */
final class TouchDevicePaths {
    private TouchDevicePaths() {}
    static List<String> select(String capabilities) {
        List<String> paths = new ArrayList<>();
        boolean powerButton = false;
        for (String block : capabilities.split("(?m)(?=^add device )")) {
            String[] lines = block.split("\\n", 2);
            int marker = lines[0].indexOf(": /dev/input/event");
            if (marker < 0) continue;
            String path = lines[0].substring(marker + 2).trim();
            if (!path.matches("/dev/input/event[0-9]+")) continue;
            boolean screen = block.contains("INPUT_PROP_DIRECT") && block.contains("ABS_MT_POSITION_X")
                && block.contains("ABS_MT_POSITION_Y");
            if (screen) paths.add(path);
            else if (block.contains("KEY_POWER")) powerButton = true;
        }
        if (!paths.isEmpty() && !powerButton)
            throw new IllegalStateException("No separate hardware power button available");
        return paths;
    }
}
