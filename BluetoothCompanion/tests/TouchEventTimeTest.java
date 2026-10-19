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
            long first=-1,last=-1; int moves=0; float previousY=0;
            while (true) {
                ControlMessage message;
                try { message=reader.read(); } catch (EOFException complete) { break; }
                require(message.getType()==ControlMessage.TYPE_INJECT_TOUCH_EVENT);
                long time=message.getEventTime();
                require(clock.resolve(time,3000)==time);
                if (first<0) { require(message.getAction()==0); first=time; }
                else {
                    require(time>last && time-last<=33);
                    if (message.getAction()==2) {
                        if (moves>0) require(Math.abs((message.getPosition().getPoint().getY()-previousY)*1000f/(time-last)+8000)<1);
                        previousY=message.getPosition().getPoint().getY(); ++moves;
                    }
                }
                last=time;
            }
            require(last-first==101 && moves>=5);

        }
        System.out.println("Touch timing: source intervals survive transport jitter, monotonic validation, legacy ADB and native-to-Android framing passed");
    }
}
