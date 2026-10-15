import com.genymobile.scrcpy.control.TouchEventTime;
import com.genymobile.scrcpy.control.ControlMessage;
import com.genymobile.scrcpy.control.ControlMessageReader;
import java.io.*;
import java.nio.file.*;

public final class TouchEventTimeTest {
    static void require(boolean condition) { if (!condition) throw new AssertionError(); }
    public static void main(String[] args) throws Exception {
        TouchEventTime clock = new TouchEventTime();
        require(clock.resolve(1000, 1200) == 1000);
        require(clock.resolve(1020, 1800) == 1020);
        require(clock.resolve(1050, 2500) == 1050); // 50 ms swipe despite 1300 ms arrival jitter.
        require(clock.resolve(1040, 2600) == 1050); // Monotonic across pointers.
        require(clock.resolve(3000, 2700) == -1);
        require(clock.resolve(0, 20000) == -1);
        require(clock.resolve(-1, 21000) == 21000); // Legacy ADB events retain arrival timestamps.
        if (args.length>0) {
            ByteArrayOutputStream payload = new ByteArrayOutputStream();
            try (DataInputStream in = new DataInputStream(Files.newInputStream(Paths.get(args[0])))) {
                while (in.available()>0) {
                    require(in.readUnsignedByte()==0); int size=in.readInt();
                    byte[] record=new byte[size]; in.readFully(record); payload.write(record);
                }
            }
            ControlMessageReader reader = new ControlMessageReader(new ByteArrayInputStream(payload.toByteArray()));
            clock = new TouchEventTime();
            long[] expected = {1000,1100,1101}; int[] actions = {0,2,1};
            for (int i=0;i<3;++i) {
                ControlMessage message=reader.read();
                require(message.getType()==ControlMessage.TYPE_INJECT_TOUCH_EVENT);
                require(message.getAction()==actions[i] && message.getEventTime()==expected[i]);
                require(clock.resolve(message.getEventTime(),2000+i*500)==expected[i]);
            }
        }
        System.out.println("Touch timing: source intervals survive transport jitter, monotonic validation, legacy ADB and native-to-Android framing passed");
    }
}
