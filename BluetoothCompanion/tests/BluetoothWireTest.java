import app.droidmirror.bluetooth.BluetoothWire;
import java.io.*;
import java.nio.file.*;
import java.util.Arrays;
public final class BluetoothWireTest {
    static void require(boolean ok) { if (!ok) throw new AssertionError(); }
    public static void main(String[] args) throws Exception {
        java.util.concurrent.atomic.AtomicLong clock = new java.util.concurrent.atomic.AtomicLong();
        BluetoothWire[] blocked = new BluetoothWire[1];
        OutputStream slowRadio = new OutputStream() {
            public void write(int value) { throw new AssertionError("Single-byte radio write"); }
            public void write(byte[] data, int offset, int length) {
                if (blocked[0] == null) return;
                clock.addAndGet(5001);
                require(!blocked[0].writeStalled(0)); // Peer is draining despite local backpressure.
                require(blocked[0].writeStalled(5001)); // Peer and writer both stopped progressing.
            }
        };
        blocked[0] = new BluetoothWire(slowRadio, clock::get);
        blocked[0].video(new byte[]{42});
        require(!blocked[0].writeStalled(5001)); // Completed write cannot trigger cancellation.
        class Packets extends ByteArrayOutputStream {
            int writes;
            public synchronized void write(int value) { throw new AssertionError("Unbuffered Bluetooth header byte"); }
            public synchronized void write(byte[] data, int offset, int length) {
                writes++; super.write(data, offset, length);
            }
        }
        Packets packets = new Packets(); BluetoothWire packetWire = new BluetoothWire(packets);
        packetWire.video(new byte[20000]); packetWire.event(BluetoothWire.ALIVE);
        packetWire.control(new byte[]{1,2}, 2);
        require(packets.writes == 3 + (20000 + BluetoothWire.VIDEO_CHUNK - 1) / BluetoothWire.VIDEO_CHUNK);
        ByteArrayOutputStream bytes = new ByteArrayOutputStream(); BluetoothWire wire = new BluetoothWire(bytes);
        byte[] video = new byte[20000]; for (int i=0;i<video.length;i++) video[i]=(byte)i;
        wire.video(video); wire.event(BluetoothWire.PHONE_ON); wire.event(BluetoothWire.STREAM_STARTED);
        DataInputStream input = new DataInputStream(new ByteArrayInputStream(bytes.toByteArray()));
        byte[] magic=new byte[8]; input.readFully(magic); require(Arrays.equals(magic,BluetoothWire.MAGIC));
        ByteArrayOutputStream received = new ByteArrayOutputStream();
        while (received.size() < video.length) {
            require(input.readByte() == 0);
            int length = input.readInt(); require(length > 0 && length <= BluetoothWire.VIDEO_CHUNK);
            byte[] chunk = new byte[length]; input.readFully(chunk); received.write(chunk);
        }
        require(Arrays.equals(video, received.toByteArray()));
        require(input.readByte()==1 && input.readInt()==1 && input.readByte()==1);
        require(input.readByte()==1 && input.readInt()==1 && input.readByte()==4 && input.available()==0);
        wire.control(new byte[]{9,8,7},3); wire.event(BluetoothWire.ALIVE);
        DataInputStream duplex = new DataInputStream(new ByteArrayInputStream(bytes.toByteArray()));
        duplex.skipBytes(bytes.size()-14);
        require(duplex.readByte()==2 && duplex.readInt()==3 && duplex.readByte()==9 && duplex.readByte()==8 && duplex.readByte()==7);
        require(duplex.readByte()==1 && duplex.readInt()==1 && duplex.readByte()==6);
        try { wire.control(new byte[1],0); throw new AssertionError(); } catch(IOException expected) {}
        try { wire.event(99); throw new AssertionError(); } catch(IOException expected) {}
        if (args.length==1) Files.write(Path.of(args[0]),bytes.toByteArray());
        System.out.println("BluetoothWire: chunk limits, event records, invalid event rejection and framing passed");
    }
}
