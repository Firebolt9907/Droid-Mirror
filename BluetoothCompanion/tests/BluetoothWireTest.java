import app.droidmirror.bluetooth.BluetoothWire;
import app.droidmirror.bluetooth.VideoWindow;
import java.io.*;
import java.nio.file.*;
import java.util.Arrays;
import java.util.concurrent.*;

public final class BluetoothWireTest {
    static void require(boolean ok) { if (!ok) throw new AssertionError(); }
    static void boundedVideoKeepsEventsResponsive() throws Exception {
        int capacity = BluetoothWire.VIDEO_WINDOW_BYTES;
        CountDownLatch full = new CountDownLatch(1);
        ByteArrayOutputStream bytes = new ByteArrayOutputStream() {
            int videoBytes;
            public synchronized void write(byte[] data, int offset, int length) {
                super.write(data, offset, length);
                if (length > 5 && data[offset] == BluetoothWire.VIDEO) {
                    videoBytes += length - 5;
                    if (videoBytes == capacity) full.countDown();
                }
            }
        };
        BluetoothWire wire = new BluetoothWire(bytes);
        ByteArrayOutputStream side = new ByteArrayOutputStream();
        wire.setSideChannel(side::write);
        VideoWindow window = new VideoWindow(capacity, 5000); wire.setVideoWindow(window);
        ExecutorService executor = Executors.newFixedThreadPool(2);
        try {
            Future<?> video = executor.submit(() -> {
                try { wire.video(new byte[capacity + BluetoothWire.VIDEO_CHUNK]); }
                catch (IOException e) { throw new RuntimeException(e); }
            });
            require(full.await(1, TimeUnit.SECONDS));
            try { video.get(30, TimeUnit.MILLISECONDS); throw new AssertionError("Window did not apply backpressure"); }
            catch (TimeoutException expected) {}
            executor.submit(() -> {
                try { wire.event(BluetoothWire.ALIVE); }
                catch (IOException e) { throw new RuntimeException(e); }
            }).get(1, TimeUnit.SECONDS);
            require(side.size() == 6);
            window.acknowledge(capacity); video.get(1, TimeUnit.SECONDS);
            require(bytes.size() == 8 + capacity + BluetoothWire.VIDEO_CHUNK + (capacity / BluetoothWire.VIDEO_CHUNK + 1) * 5);
        } finally { window.close(); executor.shutdownNow(); }
    }
    public static void main(String[] args) throws Exception {
        boundedVideoKeepsEventsResponsive();
        require(BluetoothWire.videoChunkForMtu(672) == 2683);
        for (int mtu : new int[]{0, 1, 6, 672, 1024, 12288, 65535, Integer.MAX_VALUE}) {
            int chunk=BluetoothWire.videoChunkForMtu(mtu);
            require(chunk > 0 && chunk <= BluetoothWire.VIDEO_WINDOW_BYTES && chunk <= BluetoothWire.MAX_CHUNK);
        }
        PacketsForMtu.check();
        java.util.concurrent.atomic.AtomicLong clock = new java.util.concurrent.atomic.AtomicLong();
        BluetoothWire[] blocked = new BluetoothWire[1];
        OutputStream slowRadio = new OutputStream() {
            public void write(int value) { throw new AssertionError("Single-byte radio write"); }
            public void write(byte[] data, int offset, int length) {
                if (blocked[0] == null) return;
                clock.addAndGet(5001);
                require(!blocked[0].writeStalled(0)); require(blocked[0].writeStalled(5001));
            }
        };
        blocked[0] = new BluetoothWire(slowRadio, clock::get); blocked[0].video(new byte[]{42});
        require(!blocked[0].writeStalled(5001));
        class Packets extends ByteArrayOutputStream {
            int writes;
            public synchronized void write(int value) { throw new AssertionError("Unbuffered Bluetooth header byte"); }
            public synchronized void write(byte[] data, int offset, int length) { writes++; super.write(data, offset, length); }
        }
        Packets classic = new Packets(); BluetoothWire wire = new BluetoothWire(classic);
        try { wire.event(BluetoothWire.ALIVE); throw new AssertionError("Classic fallback accepted"); } catch (IOException expected) {}
        require(classic.size() == 8);
        ByteArrayOutputStream side = new ByteArrayOutputStream(); wire.setSideChannel(side::write);
        byte[] video = new byte[20000]; for (int i=0;i<video.length;i++) video[i]=(byte)i;
        wire.video(video); wire.event(BluetoothWire.PHONE_ON); wire.event(BluetoothWire.STREAM_STARTED);
        wire.control(new byte[]{9,8,7},3); wire.event(BluetoothWire.ALIVE);
        require(classic.writes == 1 + (video.length + BluetoothWire.VIDEO_CHUNK - 1) / BluetoothWire.VIDEO_CHUNK);
        DataInputStream input = new DataInputStream(new ByteArrayInputStream(classic.toByteArray()));
        byte[] magic=new byte[8]; input.readFully(magic); require(Arrays.equals(magic,BluetoothWire.MAGIC));
        ByteArrayOutputStream received = new ByteArrayOutputStream();
        while (input.available() > 0) {
            require(input.readByte() == BluetoothWire.VIDEO);
            int length=input.readInt(); require(length > 0 && length <= BluetoothWire.VIDEO_CHUNK);
            byte[] chunk=new byte[length]; input.readFully(chunk); received.write(chunk);
        }
        require(Arrays.equals(video,received.toByteArray()));
        input = new DataInputStream(new ByteArrayInputStream(side.toByteArray()));
        require(input.readByte()==1 && input.readInt()==1 && input.readByte()==1);
        require(input.readByte()==1 && input.readInt()==1 && input.readByte()==4);
        require(input.readByte()==2 && input.readInt()==3 && input.readByte()==9 && input.readByte()==8 && input.readByte()==7);
        require(input.readByte()==1 && input.readInt()==1 && input.readByte()==6 && input.available()==0);
        try { wire.control(new byte[1],0); throw new AssertionError(); } catch(IOException expected) {}
        try { wire.event(99); throw new AssertionError(); } catch(IOException expected) {}
        if(args.length>0) Files.write(Path.of(args[0]),classic.toByteArray());
        System.out.println("BluetoothWire: Classic video only, BLE event/control isolation, no fallback, ACK backpressure and framing passed");
    }
    static class PacketsForMtu {
        static void check() throws Exception {
            ByteArrayOutputStream data=new ByteArrayOutputStream();
            int chunk=BluetoothWire.videoChunkForMtu(672);
            BluetoothWire wire=new BluetoothWire(data,()->0,chunk);
            byte[] video=new byte[7000]; for(int i=0;i<video.length;++i) video[i]=(byte)i;
            wire.video(video);
            DataInputStream input=new DataInputStream(new ByteArrayInputStream(data.toByteArray())); input.skipBytes(8);
            int count=0;
            while(input.available()>0) {
                require(input.readByte()==0); int size=input.readInt();
                require(size==Math.min(chunk,video.length-count));
                if(size==chunk) require((size+5)%672==0);
                for(int i=0;i<size;++i) require(input.readByte()==video[count++]);
            }
            require(count==video.length);
        }
    }
}
