import com.genymobile.scrcpy.control.SecureWindowState;
import com.genymobile.scrcpy.control.DeviceMessage;
import com.genymobile.scrcpy.control.DeviceMessageWriter;
import java.io.ByteArrayOutputStream;
import java.io.StringReader;
import java.nio.file.Files;
import java.nio.file.Path;

public final class SecureWindowStateTests {
    private static final String HEADER = "WINDOW MANAGER WINDOWS (dumpsys window windows)\n";
    private static String window(int id, String flags, boolean visible) {
        return "  Window #" + id + " Window{abc u0 test}:\n"
            + "    mDisplayId=" + id + " mAttrs={(fillxfill)\n      fl=" + flags + "\n    }\n"
            + "    mHasSurface=" + visible + " mObscured=false\n"
            + "    isOnScreen=" + visible + "\n    isVisible=" + visible + "\n";
    }
    private static void expect(int expected, String text, int display) {
        int actual = SecureWindowState.parse(text, display);
        if (actual != expected) throw new AssertionError("Expected " + expected + ", got " + actual + ": " + text);
    }
    public static void main(String[] args) throws Exception {
        expect(1, HEADER + window(0, "SECURE HARDWARE_ACCELERATED", true), 0);
        expect(1, HEADER + window(0, "FLAG_SECURE", true), 0);
        expect(1, HEADER + window(0, "0x00002000", true), 0);
        expect(1, HEADER + window(0, "81802900", true), 0);
        expect(0, HEADER + window(0, "HARDWARE_ACCELERATED", true), 0); // Black video has no bearing on state.
        expect(0, HEADER + window(0, "SECURE", false), 0);
        expect(0, HEADER + window(0, "SECURE", true).replace("mObscured=false", "mObscured=true"), 0);
        expect(0, HEADER + window(0, "NOT_FOCUSABLE", true) + window(1, "SECURE", true), 0);
        expect(1, HEADER + window(0, "NOT_FOCUSABLE", true) + window(1, "SECURE", true), 1);
        expect(2, HEADER + window(0, "SECURE", true), 1);
        expect(2, HEADER + window(0, "SECURE", true).replace("isVisible=true", ""), 0);
        expect(2, HEADER + window(0, "SECURE", true).replace("mDisplayId=0", ""), 0);
        expect(2, HEADER + window(0, "SECURE", true).replace("fl=SECURE", "unsupported=SECURE"), 0);
        expect(2, "Permission Denial: can't dump WindowManager", 0);
        expect(2, HEADER, 0);
        expect(2, HEADER + window(0, "SECURE", true) + "*** DUMP TIMEOUT", 0);
        expect(2, HEADER + window(0, "SECURE", true), -1);
        if (SecureWindowState.read(new StringReader("x".repeat(2 * 1024 * 1024 + 1)), 0) != 2) throw new AssertionError("Output bound");
        // The Java writer must exactly match the C reader's two-byte record.
        ByteArrayOutputStream bytes = new ByteArrayOutputStream();
        DeviceMessageWriter writer = new DeviceMessageWriter(bytes);
        for (int state = 0; state <= 2; ++state) writer.write(DeviceMessage.createSecureWindowState(state, 0x01020304));
        if (!java.util.Arrays.equals(bytes.toByteArray(), new byte[]{4, 0, 1, 2, 3, 4, 4, 1, 1, 2, 3, 4, 4, 2, 1, 2, 3, 4})) throw new AssertionError("Wire format");
        if (args.length != 0) {
            int actual = SecureWindowState.parse(Files.readString(Path.of(args[0])), 0);
            System.out.println("Live WindowManager state: " + actual + " (0=clear, 1=secure, 2=unknown)");
            if (actual == 2) throw new AssertionError("Live metadata unsupported");
        }
        System.out.println("PASS: secure/clear/unknown, visibility, displays, flags, bounded output and Java wire format");
    }
}
