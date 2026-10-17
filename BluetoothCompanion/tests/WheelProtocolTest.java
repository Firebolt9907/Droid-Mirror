import com.genymobile.scrcpy.control.ControlMessage;
import com.genymobile.scrcpy.control.ControlMessageReader;
import java.io.*;
public final class WheelProtocolTest {
    static void require(boolean value) { if(!value) throw new AssertionError(); }
    public static void main(String[] args) throws Exception {
        try(DataInputStream in=new DataInputStream(new FileInputStream(args[0]))) {
            require(in.readUnsignedByte()==0 && in.readInt()==21);
            ControlMessage m=new ControlMessageReader(in).read();
            require(m.getType()==ControlMessage.TYPE_WHEEL_SCROLL);
            require(m.getPosition().getPoint().getX()==232 && m.getPosition().getPoint().getY()==528);
            require(m.getPosition().getScreenSize().getWidth()==464 && m.getPosition().getScreenSize().getHeight()==1056);
            require(m.getHScroll()==7 && m.getVScroll()==-100);
            require(in.read()==-1);
        }
        System.out.println("Wheel protocol: native BLE framing, signed summed distances and Android decoder passed");
    }
}
