import app.droidmirror.bluetooth.*;
import java.io.*;
import java.nio.file.*;
import java.util.*;

public final class WirelessUpgradeTest {
    static final byte[] PROFILE;
    static { try { PROFILE = new WirelessVideoProfile(1920,60,12000000).bytes(); } catch (IOException error) { throw new ExceptionInInitializerError(error); } }
    static byte[] authenticated(byte[] offset) { return java.nio.ByteBuffer.allocate(PROFILE.length + offset.length).put(PROFILE).put(offset).array(); }
    static void check(boolean value) { if (!value) throw new AssertionError(); }
    static byte[] decode(byte[] bytes, int skip) throws Exception {
        DataInputStream in = new DataInputStream(new ByteArrayInputStream(bytes));
        in.skipNBytes(skip);
        check(Arrays.equals(in.readNBytes(8), BluetoothWire.MAGIC));
        ByteArrayOutputStream result = new ByteArrayOutputStream();
        while (in.available() > 0) {
            check(in.readUnsignedByte() == 0);
            int length = in.readInt();
            byte[] payload = in.readNBytes(length); check(payload.length == length);
            result.write(payload);
        }
        return result.toByteArray();
    }
    public static void main(String[] args) throws Exception {
        concurrentHandoffWaitsForRecord();
        profileValidation();
        wifiThroughputKeepsAccounting();
        byte[] key = new byte[32], nonce = new byte[32];
        for (int i=0; i<32; ++i) { key[i]=(byte)i; nonce[i]=(byte)(i+32); }
        byte[] client = WirelessUpgradeAuth.proof(key,"client",nonce,new byte[0]);
        check(!Arrays.equals(client,WirelessUpgradeAuth.proof(key,"server",nonce,new byte[0])));
        nonce[0] ^= 1;
        check(!Arrays.equals(client,WirelessUpgradeAuth.proof(key,"client",nonce,new byte[0])));
        nonce[0] ^= 1;
        // Every cutoff falls between envelopes, including inside a scrcpy frame.
        byte[] payload = new byte[70000]; new Random(42).nextBytes(payload);
        for (int split : new int[]{0,1,65,1023,1024,2683,32768,69999,70000}) {
            ByteArrayOutputStream classic = new ByteArrayOutputStream(), wifi = new ByteArrayOutputStream();
            BluetoothWire wire = new BluetoothWire(classic);
            wire.video(Arrays.copyOfRange(payload,0,split));
            check(wire.upgrade(wifi,key,nonce,PROFILE));
            check(!wire.upgrade(new ByteArrayOutputStream(),key,nonce,PROFILE));
            wire.video(Arrays.copyOfRange(payload,split,payload.length));
            DataInputStream header = new DataInputStream(new ByteArrayInputStream(wifi.toByteArray()));
            check(header.readLong() == split);
            byte[] offset = java.nio.ByteBuffer.allocate(8).putLong(split).array();
            check(Arrays.equals(header.readNBytes(32),WirelessUpgradeAuth.proof(key,"server",nonce,authenticated(offset))));
            byte[] wrong = offset.clone(); wrong[7] ^= 1;
            check(!Arrays.equals(WirelessUpgradeAuth.proof(key,"server",nonce,authenticated(offset)),WirelessUpgradeAuth.proof(key,"server",nonce,authenticated(wrong))));
            ByteArrayOutputStream joined = new ByteArrayOutputStream();
            joined.write(decode(classic.toByteArray(),0)); joined.write(decode(wifi.toByteArray(),40));
            check(Arrays.equals(payload,joined.toByteArray()));
            if (split == 2683 && args.length > 0) {
                Files.write(Path.of(args[0],"classic.bin"),classic.toByteArray());
                Files.write(Path.of(args[0],"wifi.bin"),wifi.toByteArray());
                Files.write(Path.of(args[0],"expected.bin"),payload);
            }
        }
        // A failed response write must not commit or interrupt the Bluetooth stream.
        ByteArrayOutputStream classic = new ByteArrayOutputStream(); BluetoothWire wire = new BluetoothWire(classic);
        try {
            wire.upgrade(new OutputStream() { public void write(int b) throws IOException { throw new IOException("probe failed"); } },key,nonce,PROFILE);
            throw new AssertionError();
        } catch (IOException expected) {}
        wire.video(payload); check(Arrays.equals(payload,decode(classic.toByteArray(),0)));
        check(wire.upgrade(new ByteArrayOutputStream(),key,nonce,PROFILE));
        System.out.println("Wireless upgrade: byte continuity, cutoff authentication, direction separation, failed-probe recovery passed");
    }
    static void profileValidation() throws Exception {
        WirelessVideoProfile profile = WirelessVideoProfile.parse(PROFILE);
        check(profile.maxSize==1920 && profile.fps==60 && profile.bitRate==12000000);
        check(WirelessVideoProfile.parse(new WirelessVideoProfile(0,90,32000000).bytes()).maxSize==0);
        for (int[] invalid : new int[][]{{-1,60,12000000},{64,60,12000000},{8193,60,12000000},
                {1920,0,12000000},{1920,241,12000000},{1920,60,0},{1920,60,64000001}}) {
            try { new WirelessVideoProfile(invalid[0],invalid[1],invalid[2]); throw new AssertionError(); }
            catch (IOException expected) {}
        }
        try { WirelessVideoProfile.parse(new byte[11]); throw new AssertionError(); } catch (IOException expected) {}
        byte[] key=new byte[32], nonce=new byte[32], changed=PROFILE.clone(); changed[7]^=1;
        check(!Arrays.equals(WirelessUpgradeAuth.proof(key,"client",nonce,PROFILE),WirelessUpgradeAuth.proof(key,"client",nonce,changed)));
    }
    static void wifiThroughputKeepsAccounting() throws Exception {
        VideoWindow window = new VideoWindow(BluetoothWire.VIDEO_WINDOW_BYTES,1000);
        window.reserve(BluetoothWire.VIDEO_WINDOW_BYTES);
        ByteArrayOutputStream classic = new ByteArrayOutputStream(), wifi = new ByteArrayOutputStream();
        BluetoothWire wire = new BluetoothWire(classic); wire.setVideoWindow(window);
        try { wire.enableWirelessThroughput(); throw new AssertionError(); } catch (IllegalStateException expected) {}
        check(wire.upgrade(wifi,new byte[32],new byte[32],PROFILE));
        java.util.concurrent.ExecutorService executor = java.util.concurrent.Executors.newSingleThreadExecutor();
        try {
            byte[] largeFrame = new byte[1024*1024];
            java.util.concurrent.Future<?> sending = executor.submit(() -> {
                try { wire.video(largeFrame); } catch (IOException error) { throw new RuntimeException(error); }
            });
            try { sending.get(30,java.util.concurrent.TimeUnit.MILLISECONDS); throw new AssertionError("Expanded before receiver confirmation"); }
            catch (java.util.concurrent.TimeoutException expected) {}
            wire.enableWirelessThroughput();
            long deadline=System.nanoTime()+2_000_000_000L;
            while (!sending.isDone() && System.nanoTime()<deadline) {
                Thread.sleep(5);
                long inFlight=window.inFlightBytes();
                check(inFlight<=VideoWindow.WIRELESS_WINDOW_BYTES);
                window.acknowledge(window.acknowledgedBytes()+inFlight);
            }
            sending.get(2,java.util.concurrent.TimeUnit.SECONDS);
            long sent = BluetoothWire.VIDEO_WINDOW_BYTES + largeFrame.length;
            check(window.acknowledgedBytes()+window.inFlightBytes()==sent);
            window.acknowledge(sent); check(window.inFlightBytes()==0);
            try { window.acknowledge(sent+1); throw new AssertionError(); } catch (IOException expected) {}
            check(Arrays.equals(largeFrame,decode(wifi.toByteArray(),40)));
        } finally { window.close(); executor.shutdownNow(); }
    }
    static void concurrentHandoffWaitsForRecord() throws Exception {
        java.util.concurrent.CountDownLatch writing = new java.util.concurrent.CountDownLatch(1);
        java.util.concurrent.CountDownLatch release = new java.util.concurrent.CountDownLatch(1);
        ByteArrayOutputStream classic = new ByteArrayOutputStream() {
            public synchronized void write(byte[] bytes, int offset, int length) {
                if (size() >= 8) {
                    writing.countDown();
                    try { check(release.await(2,java.util.concurrent.TimeUnit.SECONDS)); }
                    catch (InterruptedException error) { throw new AssertionError(error); }
                }
                super.write(bytes,offset,length);
            }
        };
        BluetoothWire wire = new BluetoothWire(classic);
        ByteArrayOutputStream wifi = new ByteArrayOutputStream();
        java.util.concurrent.ExecutorService executor = java.util.concurrent.Executors.newFixedThreadPool(2);
        try {
            java.util.concurrent.Future<?> video = executor.submit(() -> {
                try { wire.video(new byte[]{1,2,3}); } catch (IOException error) { throw new RuntimeException(error); }
            });
            check(writing.await(1,java.util.concurrent.TimeUnit.SECONDS));
            java.util.concurrent.Future<Boolean> upgrade = executor.submit(() -> wire.upgrade(wifi,new byte[32],new byte[32],PROFILE));
            try { upgrade.get(30,java.util.concurrent.TimeUnit.MILLISECONDS); throw new AssertionError("Split an in-flight record"); }
            catch (java.util.concurrent.TimeoutException expected) {}
            release.countDown(); video.get(1,java.util.concurrent.TimeUnit.SECONDS);
            check(upgrade.get(1,java.util.concurrent.TimeUnit.SECONDS));
            check(new DataInputStream(new ByteArrayInputStream(wifi.toByteArray())).readLong()==3);
            check(Arrays.equals(decode(classic.toByteArray(),0),new byte[]{1,2,3}));
        } finally { release.countDown(); executor.shutdownNow(); }
    }
}
