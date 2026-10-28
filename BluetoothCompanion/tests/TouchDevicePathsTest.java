package app.droidmirror.bluetooth;
import java.util.List;
public final class TouchDevicePathsTest {
    public static void main(String[] args) {
        String power = "add device 1: /dev/input/event0\n  name: gpio_keys\n  KEY_POWER\n";
        String screen = "add device 2: /dev/input/event3\n  KEY_POWER ABS_MT_POSITION_X ABS_MT_POSITION_Y\n  INPUT_PROP_DIRECT\n";
        String pad = "add device 3: /dev/input/event4\n  ABS_MT_POSITION_X ABS_MT_POSITION_Y\n  INPUT_PROP_POINTER\n";
        if (!TouchDevicePaths.select(power + screen + pad).equals(List.of("/dev/input/event3"))) throw new AssertionError("Screen selection");
        boolean refused = false;
        try { TouchDevicePaths.select(screen); } catch (IllegalStateException expected) { refused = true; }
        if (!refused) throw new AssertionError("Must preserve separate power button");
        if (!TouchDevicePaths.select(power + pad).isEmpty()) throw new AssertionError("Touchpad selected");
        String second = screen.replace("event3", "event5");
        if (!TouchDevicePaths.select(power + screen + second).equals(List.of("/dev/input/event3", "/dev/input/event5"))) throw new AssertionError("Multiple screens");
        System.out.println("TouchDevicePaths: touchscreens, touchpad exclusion and power-button escape passed");
    }
}
