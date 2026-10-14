import app.droidmirror.bluetooth.BluetoothWire;
import java.io.*;
import java.nio.file.*;
import java.util.Arrays;
public final class BluetoothWireTest {
    static void require(boolean ok) { if (!ok) throw new AssertionError(); }
    public static void main(String[] args) throws Exception {
        ByteArrayOutputStream bytes = new ByteArrayOutputStream(); BluetoothWire wire = new BluetoothWire(bytes);
        byte[] video = new byte[20000]; for (int i=0;i<video.length;i++) video[i]=(byte)i;
        wire.video(video); wire.event(BluetoothWire.PHONE_ON); wire.event(BluetoothWire.STREAM_STARTED);
        DataInputStream input = new DataInputStream(new ByteArrayInputStream(bytes.toByteArray()));
        byte[] magic=new byte[8]; input.readFully(magic); require(Arrays.equals(magic,BluetoothWire.MAGIC));
        require(input.readByte()==0 && input.readInt()==16384); byte[] a=new byte[16384]; input.readFully(a);
        require(input.readByte()==0 && input.readInt()==3616); byte[] b=new byte[3616]; input.readFully(b);
        require(Arrays.equals(a,Arrays.copyOfRange(video,0,16384)) && Arrays.equals(b,Arrays.copyOfRange(video,16384,20000)));
        require(input.readByte()==1 && input.readInt()==1 && input.readByte()==1);
        require(input.readByte()==1 && input.readInt()==1 && input.readByte()==4 && input.available()==0);
        try { wire.event(99); throw new AssertionError(); } catch(IOException expected) {}
        if (args.length==1) Files.write(Path.of(args[0]),bytes.toByteArray());
        System.out.println("BluetoothWire: chunk limits, event records, invalid event rejection and framing passed");
    }
}
