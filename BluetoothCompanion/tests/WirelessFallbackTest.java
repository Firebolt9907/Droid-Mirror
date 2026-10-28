import app.droidmirror.bluetooth.*;
import java.io.*;
import java.nio.file.*;
import java.util.*;
import java.util.concurrent.*;

/** Disconnects within both envelope headers and HEVC payload; never restarts scrcpy. */
public final class WirelessFallbackTest {
    static void check(boolean value) { if (!value) throw new AssertionError(); }
    static final class BrokenSocket extends OutputStream {
        final ByteArrayOutputStream received=new ByteArrayOutputStream();
        int remaining=Integer.MAX_VALUE;
        final CountDownLatch broken=new CountDownLatch(1);
        public void write(int value) throws IOException {
            if (remaining--<=0) { broken.countDown(); throw new IOException("ADB disconnected mid-record"); }
            received.write(value);
        }
    }
    static byte[] payload(byte[] wire, int skip, boolean incomplete) throws Exception {
        ByteArrayOutputStream result=new ByteArrayOutputStream();
        DataInputStream input=new DataInputStream(new ByteArrayInputStream(wire)); input.skipNBytes(skip);
        while (input.available()!=0) {
            if (input.available()<5) { check(incomplete); break; }
            int type=input.readUnsignedByte(), count=input.readInt(); check(type==0 && count>0 && count<=16384);
            byte[] bytes=input.readNBytes(count); result.write(bytes);
            if (bytes.length<count) { check(incomplete); break; }
        }
        return result.toByteArray();
    }
    public static void main(String[] args) throws Exception {
        byte[] expected=new byte[70000]; new Random(91).nextBytes(expected);
        byte[] key=new byte[32],nonce=new byte[32],profile=new WirelessVideoProfile(1920,60,12000000).bytes();
        ExecutorService executor=Executors.newSingleThreadExecutor();
        try {
            for (int cut : new int[]{0,1,4,5,6,12,16388,16389,16390,30000,65555}) {
                ByteArrayOutputStream classic=new ByteArrayOutputStream();
                BluetoothWire wire=new BluetoothWire(classic); wire.video(Arrays.copyOf(expected,700));
                byte[] initial=classic.toByteArray();
                BrokenSocket wifi=new BrokenSocket(); check(wire.upgrade(wifi,key,nonce,profile)); wifi.remaining=cut;
                Future<?> sender=executor.submit(() -> {
                    try { wire.video(Arrays.copyOfRange(expected,700,expected.length)); }
                    catch (IOException failed) { throw new RuntimeException(failed); }
                });
                check(wifi.broken.await(2,TimeUnit.SECONDS));
                // Snapshot only after the failed write has completed/released its monitor.
                byte[] partial=wifi.received.toByteArray(); byte[] accepted=payload(partial,48,true);
                check(wire.fallback(700+accepted.length));
                sender.get(2,TimeUnit.SECONDS); check(!wire.isWireless());
                check(!wire.fallback(700+accepted.length)); // Duplicate BLE signal is harmless.
                byte[] resumed=Arrays.copyOfRange(classic.toByteArray(),initial.length,classic.size());
                ByteArrayOutputStream joined=new ByteArrayOutputStream();
                joined.write(payload(initial,8,false)); joined.write(accepted); joined.write(payload(resumed,0,false));
                check(Arrays.equals(joined.toByteArray(),expected));
                if (cut==30000 && args.length!=0) {
                    Files.write(Path.of(args[0],"fallback-initial.bin"),initial);
                    Files.write(Path.of(args[0],"fallback-wifi.bin"),partial);
                    Files.write(Path.of(args[0],"fallback-resumed.bin"),resumed);
                    Files.write(Path.of(args[0],"fallback-expected.bin"),expected);
                }
                // A recovered session can upgrade again without another device/codec header.
                check(wire.upgrade(new ByteArrayOutputStream(),key,nonce,profile));
                check(wire.fallback(expected.length));
            }
            // Live fallback retires the entire Wi-Fi window without sending it
            // on Classic, accepts delayed ACKs, and waits for new codec metadata.
            ByteArrayOutputStream liveClassic=new ByteArrayOutputStream();
            BluetoothWire live=new BluetoothWire(liveClassic);
            VideoWindow liveWindow=new VideoWindow(8192,1000);
            live.setVideoWindow(liveWindow);
            live.videoFrameSent(new byte[]{1});
            check(live.upgrade(new ByteArrayOutputStream(),key,nonce,profile));
            live.enableWirelessThroughput(); live.video(expected);
            check(live.fallbackLive(0));
            check(liveClassic.size()==8+13); // magic + reset, zero replay bytes
            DataInputStream reset=new DataInputStream(new ByteArrayInputStream(liveClassic.toByteArray()));
            reset.skipNBytes(8); check(reset.readUnsignedByte()==8 && reset.readInt()==8);
            check(reset.readLong()==expected.length);
            liveWindow.acknowledge(100); // Old Wi-Fi ACK can cross recovery.
            check(liveWindow.inFlightBytes()==0);
            live.videoPacket(new byte[20]); check(liveClassic.size()==21);
            byte[] session=new byte[12]; session[0]=(byte)0x80;
            live.videoPacket(session);
            check(liveClassic.size()==38);
            liveWindow.acknowledge(expected.length+12);
            check(!live.fallbackLive(expected.length+12));
            // A sender interrupted mid-envelope must abandon the remainder of
            // that whole packet instead of continuing it after the reset marker.
            ByteArrayOutputStream interruptedClassic=new ByteArrayOutputStream();
            BluetoothWire interrupted=new BluetoothWire(interruptedClassic);
            interrupted.videoFrameSent(new byte[]{1});
            BrokenSocket interruptedWifi=new BrokenSocket();
            check(interrupted.upgrade(interruptedWifi,key,nonce,profile));
            interruptedWifi.remaining=1000;
            Future<?> interruptedSender=executor.submit(() -> {
                try { interrupted.video(expected); }
                catch(IOException error) { throw new RuntimeException(error); }
            });
            check(interruptedWifi.broken.await(2,TimeUnit.SECONDS));
            check(interrupted.fallbackLive(995));
            interruptedSender.get(2,TimeUnit.SECONDS);
            check(interruptedClassic.size()==21);

            ByteArrayOutputStream blockedClassic=new ByteArrayOutputStream();
            BluetoothWire blocked=new BluetoothWire(blockedClassic);
            VideoWindow blockedWindow=new VideoWindow(8192,1000);
            blocked.setVideoWindow(blockedWindow); blocked.videoFrameSent(new byte[]{1});
            check(blocked.upgrade(new ByteArrayOutputStream(),key,nonce,profile));
            blocked.enableWirelessThroughput(); blocked.video(new byte[VideoWindow.WIRELESS_WINDOW_BYTES]);
            Future<?> blockedSender=executor.submit(() -> {
                try { blocked.video(expected); }
                catch(IOException error) { throw new RuntimeException(error); }
            });
            Thread.sleep(30);
            check(blocked.fallbackLive(0)); blockedSender.get(2,TimeUnit.SECONDS);
            check(blockedClassic.size()==21 && blockedWindow.inFlightBytes()==0);
            // A full Wi-Fi backlog must respect Bluetooth credit during replay.
            ByteArrayOutputStream pacedClassic=new ByteArrayOutputStream();
            BluetoothWire pacedWire=new BluetoothWire(pacedClassic);
            VideoWindow window=new VideoWindow(BluetoothWire.VIDEO_WINDOW_BYTES,1000);
            pacedWire.setVideoWindow(window);
            check(pacedWire.upgrade(new ByteArrayOutputStream(),key,nonce,profile));
            pacedWire.enableWirelessThroughput(); pacedWire.video(expected);
            Future<?> recovery=executor.submit(() -> {
                try { check(pacedWire.fallback(0)); }
                catch(IOException error) { throw new RuntimeException(error); }
            });
            long delivered=0, replayDeadline=System.nanoTime()+5_000_000_000L;
            while (delivered<expected.length && System.nanoTime()<replayDeadline) {
                Thread.sleep(20);
                byte[] bytes=payload(pacedClassic.toByteArray(),8,false);
                check(bytes.length-delivered<=BluetoothWire.VIDEO_WINDOW_BYTES);
                delivered=bytes.length;
                window.acknowledge(delivered);
            }
            check(delivered==expected.length);
            recovery.get(2,TimeUnit.SECONDS);
            check(Arrays.equals(payload(pacedClassic.toByteArray(),8,false),expected));
            check(window.inFlightBytes()==0);
            // Confirmation can fail while pre-handoff Classic bytes are in flight.
            BluetoothWire wire=new BluetoothWire(new ByteArrayOutputStream());
            wire.video(new byte[]{1,2,3}); check(wire.upgrade(new ByteArrayOutputStream(),key,nonce,profile));
            check(wire.fallback(0)); // Original ordered Classic bytes must not be duplicated.
            System.out.println("Wireless fallback: BLE resume offsets, mid-header/payload loss, exact decoder continuity, duplicate requests and repeated handoffs passed");
        } finally { executor.shutdownNow(); }
    }
}
