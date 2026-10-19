package app.droidmirror.bluetooth;

import java.io.*;
import java.net.Socket;
import java.util.concurrent.*;
import java.util.concurrent.atomic.AtomicInteger;

public final class WirelessAudioProtocolTest {
    static void check(boolean ok) { if (!ok) throw new AssertionError(); }
    public static void main(String[] args) throws Exception {
        byte[] key=new byte[32], profile=new WirelessVideoProfile(1920,60,12000000).bytes();
        ByteArrayOutputStream classic=new ByteArrayOutputStream();
        BluetoothWire wire=new BluetoothWire(classic); wire.video(new byte[]{1,2,3});
        try { wire.audioRecord(7,new byte[12]); throw new AssertionError(); } catch(IOException expected) {}
        CountDownLatch upgraded=new CountDownLatch(1), poll=new CountDownLatch(1), start=new CountDownLatch(1), stop=new CountDownLatch(1);
        AtomicInteger starts=new AtomicInteger(), polls=new AtomicInteger();
        WirelessVideoUpgrade.AudioSession audio=new WirelessVideoUpgrade.AudioSession() {
            public void poll() throws IOException { polls.incrementAndGet(); poll.countDown(); }
            public void start() throws IOException {
                starts.incrementAndGet(); wire.audioRecord(7,new byte[12]); start.countDown();
            }
            public void stop() { stop.countDown(); }
        };
        try (WirelessVideoUpgrade endpoint=new WirelessVideoUpgrade(wire,key,p -> { if(p!=null) upgraded.countDown(); },false,audio);
             Socket socket=WirelessVideoUpgradeTest.connect()) {
            byte[] nonce=WirelessVideoUpgradeTest.authenticate(socket,key,profile,wire);
            socket.getOutputStream().write(1); socket.getOutputStream().flush();
            check(upgraded.await(2,TimeUnit.SECONDS));
            // Legacy receivers keep video without receiving unknown audio records.
            check(!poll.await(350,TimeUnit.MILLISECONDS)); check(starts.get()==0);
            socket.getOutputStream().write(4); socket.getOutputStream().flush();
            check(poll.await(2,TimeUnit.SECONDS)); check(starts.get()==0);
            int classicLength=classic.size();
            socket.getOutputStream().write(2); socket.getOutputStream().flush();
            check(start.await(2,TimeUnit.SECONDS)); check(starts.get()==1 && polls.get()>0);
            DataInputStream input=new DataInputStream(socket.getInputStream());
            int type;
            do {
                type=input.readUnsignedByte(); int length=input.readInt();
                check(length<=4104); check(input.readNBytes(length).length==length);
            } while(type!=7);
            check(classic.size()==classicLength); // PCM never enters Classic/video replay.
            socket.getOutputStream().write(3); socket.getOutputStream().flush();
            check(stop.await(2,TimeUnit.SECONDS));
            endpoint.fallback(nonce,12);
            long until=System.nanoTime()+2_000_000_000L;
            while(wire.isWireless() && System.nanoTime()<until) Thread.sleep(5);
            check(!wire.isWireless());
            try { wire.audioRecord(6,new byte[]{1}); throw new AssertionError(); } catch(IOException expected) {}
        }
        System.out.println("Wireless audio: legacy opt-out, authenticated negotiation, explicit Start/Stop, Wi-Fi-only records and fallback passed");
    }
}
