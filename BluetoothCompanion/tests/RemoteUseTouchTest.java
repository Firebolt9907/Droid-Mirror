import com.genymobile.scrcpy.RemoteUseTouch;

public final class RemoteUseTouchTest {
    private static void check(boolean expected, String line) {
        if (RemoteUseTouch.isContact(line) != expected) throw new AssertionError(line);
    }
    public static void main(String[] args) {
        check(true, "[ 110.200000] /dev/input/event3: EV_KEY BTN_TOUCH DOWN");
        check(true, "/dev/input/event3: EV_KEY BTN_TOUCH 00000001");
        check(true, "[ 110.200000] /dev/input/event3: EV_ABS ABS_MT_TRACKING_ID 00000000");
        check(true, "[ 110.200000] /dev/input/event3: EV_ABS ABS_MT_TRACKING_ID 00001234");
        check(false, "[ 110.200000] /dev/input/event3: EV_ABS ABS_MT_TRACKING_ID ffffffff");
        check(false, "[ 110.200000] /dev/input/event3: EV_KEY BTN_TOUCH UP");
        check(false, "/dev/input/event3: EV_ABS ABS_MT_POSITION_X 00000001");
        check(false, "/dev/input/event1: EV_ABS ABS_DISTANCE 00000001");
        check(false, "/dev/input/event0: EV_KEY KEY_POWER DOWN");
        check(false, "/dev/input/event2: EV_KEY KEY_HOME DOWN");
        check(false, "could not open /dev/input/event3: Permission denied");
        check(false, "");
        System.out.println("RemoteUseTouch: contact starts, releases, proximity and hardware keys passed");
    }
}
