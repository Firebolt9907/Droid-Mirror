package app.droidmirror.bluetooth;

import java.io.*;
import java.util.Arrays;
import java.util.concurrent.*;

/** Exercises startup selection and replay without radios or socket substitutes. */
public final class BluetoothInitialPathTest {
    static void check(boolean value) { if (!value) throw new AssertionError(); }
    public static void main(String[] args) throws Exception {
        byte[] key=new byte[32], nonce=new byte[32];
        byte[] profile=new WirelessVideoProfile(1920,60,12000000).bytes();
        ByteArrayOutputStream firstClassic=new ByteArrayOutputStream(), lateLan=new ByteArrayOutputStream();
        BluetoothWire firstBluetooth=new BluetoothWire(firstClassic);
        firstBluetooth.video(new byte[]{1,2,3});
        check(!firstBluetooth.upgradeInitial(lateLan,key,nonce,profile));
        check(lateLan.size()==0 && firstClassic.size()==16);
        ExecutorService workers=Executors.newFixedThreadPool(2);
        try {
            for(int round=0;round<100;round++) {
                ByteArrayOutputStream classic=new ByteArrayOutputStream(), lan=new ByteArrayOutputStream();
                BluetoothWire wire=new BluetoothWire(classic);
                CountDownLatch go=new CountDownLatch(1);
                Future<Boolean> candidate=workers.submit(() -> { go.await(); return wire.upgradeInitial(lan,key,nonce,profile); });
                Future<?> video=workers.submit(() -> {
                    try { go.await(); wire.video(new byte[]{1,2,3}); }
                    catch(Exception error) { throw new RuntimeException(error); }
                });
                go.countDown(); boolean initial=candidate.get(2,TimeUnit.SECONDS); video.get(2,TimeUnit.SECONDS);
                if(initial) {
                    check(classic.size()==8);
                    DataInputStream input=new DataInputStream(new ByteArrayInputStream(lan.toByteArray()));
                    check(input.readInt()==-3 && input.readLong()==0);
                    byte[] authenticated=java.nio.ByteBuffer.allocate(20).put(profile).putLong(0).array();
                    check(Arrays.equals(input.readNBytes(32),WirelessUpgradeAuth.proof(key,"initial server",nonce,authenticated)));
                    check(Arrays.equals(input.readNBytes(8),BluetoothWire.MAGIC));
                    check(input.readUnsignedByte()==0 && input.readInt()==3);
                    check(Arrays.equals(input.readNBytes(3),new byte[]{1,2,3}) && input.available()==0);
                    // A partial first LAN packet must replay precisely its remaining bytes.
                    check(wire.fallback(1));
                    input=new DataInputStream(new ByteArrayInputStream(classic.toByteArray())); input.skipNBytes(8);
                    check(input.readUnsignedByte()==0 && input.readInt()==2);
                    check(Arrays.equals(input.readNBytes(2),new byte[]{2,3}) && input.available()==0);
                } else {
                    check(lan.size()==0 && !wire.isWireless());
                    check(classic.size()==16);
                }
                // A second startup candidate cannot steal an already chosen stream.
                check(!wire.upgradeInitial(new ByteArrayOutputStream(),key,nonce,profile));
            }
        } finally { workers.shutdownNow(); }
        System.out.println("Initial path: 100 concurrent first-packet races, authenticated zero cutoff, no duplicate video and partial-packet recovery passed");
    }
}
