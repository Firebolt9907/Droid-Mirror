package app.droidmirror.bluetooth;

import java.io.*;
import java.net.*;
import java.util.Arrays;
import java.util.concurrent.*;

/** Runs the production endpoint over JVM socket substitutes; no Android radio/codec claims. */
public final class WirelessVideoUpgradeTest {
    static void check(boolean value) { if (!value) throw new AssertionError(); }
    static Socket connect() throws IOException {
        Socket socket = new Socket(InetAddress.getLoopbackAddress(),android.net.LocalServerSocket.testPort);
        socket.setSoTimeout(2000);
        return socket;
    }
    static int previewLength(DataInputStream input) throws IOException {
        int length;
        while ((length=input.readInt())==-2) check(input.readLong()>0);
        return length;
    }
    static byte[] nonce(DataInputStream input) throws IOException {
        String magic=new String(input.readNBytes(8),java.nio.charset.StandardCharsets.US_ASCII);
        check(magic.equals("DMWIFI05") || magic.equals("DMWIFI06"));
        byte[] nonce=input.readNBytes(32); check(nonce.length==32); return nonce;
    }
    static byte[] authenticate(Socket socket, byte[] key, byte[] profile, BluetoothWire wire) throws Exception {
        DataInputStream input=new DataInputStream(socket.getInputStream());
        byte[] nonce=nonce(input);
        DataOutputStream output=new DataOutputStream(socket.getOutputStream());
        output.write(profile); output.write(WirelessUpgradeAuth.proof(key,"client",nonce,profile)); output.flush();
        check(Arrays.equals(input.readNBytes(32),WirelessUpgradeAuth.proof(key,"preview server",nonce,profile)));
        // The candidate has not committed: Classic must keep carrying frames.
        check(!wire.isWireless());
        int frames=0;
        for (int i=0;i<3;i++) {
            wire.video(new byte[]{11,12,13}); wire.videoFrameSent();
            check(previewLength(input)==3);
            check(Arrays.equals(input.readNBytes(3),new byte[]{11,12,13}));
            check(previewLength(input)==0); frames++;
            check(!wire.isWireless());
        }
        check(frames==3);
        output.writeByte(1); output.flush();
        check(previewLength(input)==-1);
        byte[] response=input.readNBytes(48); check(response.length==48);
        check(java.nio.ByteBuffer.wrap(response).getLong()>=3);
        byte[] authenticated=java.nio.ByteBuffer.allocate(20).put(profile).put(response,0,8).array();
        check(Arrays.equals(Arrays.copyOfRange(response,8,40),WirelessUpgradeAuth.proof(key,"server",nonce,authenticated)));
        check(Arrays.equals(Arrays.copyOfRange(response,40,48),BluetoothWire.MAGIC));
        return nonce;
    }
    static void initialPathWins(int connection) throws Exception {
        byte[] key=new byte[32];
        byte[] profile=new WirelessVideoProfile(1920,60,12000000).bytes();
        ByteArrayOutputStream classic=new ByteArrayOutputStream();
        BluetoothWire wire=new BluetoothWire(classic);
        CountDownLatch quality=new CountDownLatch(1), restored=new CountDownLatch(1);
        try (WirelessVideoUpgrade endpoint=new WirelessVideoUpgrade(wire,key,p -> {
            if (p!=null) quality.countDown(); else restored.countDown();
        },true); Socket socket=connect()) {
            DataInputStream input=new DataInputStream(socket.getInputStream());
            check(Arrays.equals(input.readNBytes(8),"DMWIFI06".getBytes(java.nio.charset.StandardCharsets.US_ASCII)));
            byte[] nonce=input.readNBytes(32);
            OutputStream output=socket.getOutputStream();
            output.write(profile); output.write(WirelessUpgradeAuth.proof(key,"client",nonce,profile)); output.flush();
            check(Arrays.equals(input.readNBytes(32),WirelessUpgradeAuth.proof(key,"preview server",nonce,profile)));
            check(input.readInt()==-3);
            byte[] response=input.readNBytes(48); check(response.length==48);
            check(java.nio.ByteBuffer.wrap(response).getLong()==0);
            byte[] authenticated=java.nio.ByteBuffer.allocate(20).put(profile).putLong(0).array();
            check(Arrays.equals(Arrays.copyOfRange(response,8,40),WirelessUpgradeAuth.proof(key,"initial server",nonce,authenticated)));
            check(Arrays.equals(Arrays.copyOfRange(response,40,48),BluetoothWire.MAGIC));
            check(wire.connectionMethod()==BluetoothWire.CONNECTION_BLUETOOTH);
            output.write(connection); output.flush();
            check(!quality.await(50,TimeUnit.MILLISECONDS)); // BLE/capture are still starting.
            endpoint.captureReady(); check(quality.await(2,TimeUnit.SECONDS));
            check(wire.connectionMethod()==connection);
            wire.video(new byte[]{1,2,3});
            int type=input.readUnsignedByte();
            while (type==BluetoothWire.EVENT) { check(input.readInt()==1); input.readByte(); type=input.readUnsignedByte(); }
            check(type==0 && input.readInt()==3 && Arrays.equals(input.readNBytes(3),new byte[]{1,2,3}));
            check(classic.size()==8); // No video packet ever travelled over Classic.
            endpoint.fallback(new byte[32],2);
            check(wire.connectionMethod()==connection); // Wrong nonce cannot change the indicator.
            endpoint.fallback(nonce,2); check(restored.await(2,TimeUnit.SECONDS));
            long until=System.nanoTime()+2_000_000_000L;
            while(wire.isWireless() && System.nanoTime()<until) Thread.sleep(5);
            check(!wire.isWireless() && classic.size()>8);
            check(wire.connectionMethod()==BluetoothWire.CONNECTION_BLUETOOTH);
        }
        System.out.println("LAN startup wins: zero cutoff, distinct proof, first packet on LAN, capture readiness and authenticated replay passed");
    }
    static void bluetoothWinsStartup() throws Exception {
        byte[] key=new byte[32];
        byte[] profile=new WirelessVideoProfile(1920,60,12000000).bytes();
        BluetoothWire wire=new BluetoothWire(new ByteArrayOutputStream());
        wire.video(new byte[]{1,2,3});
        try (WirelessVideoUpgrade endpoint=new WirelessVideoUpgrade(wire,key,p -> {},true); Socket socket=connect()) {
            authenticate(socket,key,profile,wire);
            endpoint.captureReady(); socket.getOutputStream().write(1); socket.getOutputStream().flush();
        }
        System.out.println("Bluetooth startup wins: delayed LAN uses live preview and exact cutoff");
    }
    public static void main(String[] args) throws Exception {
        initialPathWins(BluetoothWire.CONNECTION_WIFI);
        initialPathWins(BluetoothWire.CONNECTION_USB);
        bluetoothWinsStartup();
        blockedWarmupKeepsBluetooth();
        staticScreenCanUpgrade();
        byte[] key=new byte[32]; Arrays.fill(key,(byte)42);
        byte[] profile=new WirelessVideoProfile(1920,60,12000000).bytes();
        ByteArrayOutputStream classic=new ByteArrayOutputStream();
        BluetoothWire wire=new BluetoothWire(classic); wire.video(new byte[]{1,2,3});
        CountDownLatch quality=new CountDownLatch(1), restored=new CountDownLatch(1);
        byte[] sessionNonce=null;
        try (WirelessVideoUpgrade endpoint=new WirelessVideoUpgrade(wire,key,requested -> {
            if (requested==null) { restored.countDown(); return; }
            check(requested.maxSize==1920 && requested.fps==60 && requested.bitRate==12000000);
            check(wire.isWireless()); quality.countDown();
        })) {
            try (Socket wrong=connect()) {
                DataInputStream input=new DataInputStream(wrong.getInputStream()); nonce(input);
                wrong.getOutputStream().write(new byte[44]);
                check(input.read()==-1); check(!wire.isWireless());
            }
            try (Socket good=connect()) {
                sessionNonce=authenticate(good,key,profile,wire);
                check(!quality.await(40,TimeUnit.MILLISECONDS));
                good.getOutputStream().write(1); good.getOutputStream().flush();
                check(quality.await(2,TimeUnit.SECONDS));
                wire.video(new byte[]{4,5,6});
                DataInputStream received=new DataInputStream(good.getInputStream());
                int type=received.readUnsignedByte(), length=received.readInt();
                while (type==1 || type==5) {
                    if (type==1) check(length==1 && received.readByte()==6);
                    else check(length==8 && received.readLong()>0);
                    type=received.readUnsignedByte(); length=received.readInt();
                }
                check(type==0 && length==3);
                check(Arrays.equals(received.readNBytes(3),new byte[]{4,5,6}));
            }
            // The socket disappearing alone must not start Bluetooth video.
            Thread.sleep(30); check(wire.isWireless());
            endpoint.fallback(new byte[32],5); check(wire.isWireless());
            endpoint.fallback(sessionNonce,14); // Authenticated BLE request after a partial frame.
            check(restored.await(2,TimeUnit.SECONDS));
            long until=System.nanoTime()+2_000_000_000L;
            while (wire.isWireless() && System.nanoTime()<until) Thread.sleep(5);
            check(!wire.isWireless());
            try (Socket again=connect()) {
                authenticate(again,key,profile,wire);
                endpoint.fallback(sessionNonce,15); check(wire.isWireless()); // Stale connection signal.
                again.getOutputStream().write(1); again.getOutputStream().flush();
            }
        }
        // An authenticated but invalid profile must not commit the transport.
        BluetoothWire invalidWire=new BluetoothWire(new ByteArrayOutputStream());
        try (WirelessVideoUpgrade endpoint=new WirelessVideoUpgrade(invalidWire,key,p -> { throw new AssertionError(); }); Socket socket=connect()) {
            DataInputStream input=new DataInputStream(socket.getInputStream()); byte[] nonce=nonce(input);
            byte[] invalid=new byte[12];
            socket.getOutputStream().write(invalid);
            socket.getOutputStream().write(WirelessUpgradeAuth.proof(key,"client",nonce,invalid));
            check(input.read()==-1); check(!invalidWire.isWireless());
        }
        // A failed receiver confirmation can recover through the BLE request.
        BluetoothWire failedWire=new BluetoothWire(new ByteArrayOutputStream()); failedWire.video(new byte[]{1,2,3});
        try (WirelessVideoUpgrade endpoint=new WirelessVideoUpgrade(failedWire,key,p -> { check(p==null); }); Socket socket=connect()) {
            byte[] failedNonce=authenticate(socket,key,profile,failedWire); socket.getOutputStream().write(0);
            check(socket.getInputStream().read()==-1);
            endpoint.fallback(failedNonce,12);
            long until=System.nanoTime()+2_000_000_000L;
            while (failedWire.isWireless() && System.nanoTime()<until) Thread.sleep(5);
            check(!failedWire.isWireless());
        }
        // Android's raw fd close does not necessarily release a native write.
        // Keep that write blocked until shutdownOutput, then recover the same stream.
        BluetoothWire blockedWire=new BluetoothWire(new ByteArrayOutputStream()); blockedWire.video(new byte[]{1,2,3});
        CountDownLatch upgraded=new CountDownLatch(1);
        ExecutorService sender=Executors.newSingleThreadExecutor();
        try (WirelessVideoUpgrade endpoint=new WirelessVideoUpgrade(blockedWire,key,p -> { if (p!=null) upgraded.countDown(); }); Socket socket=connect()) {
            byte[] active=authenticate(socket,key,profile,blockedWire);
            socket.getOutputStream().write(1); socket.getOutputStream().flush();
            check(upgraded.await(2,TimeUnit.SECONDS));
            android.net.LocalSocket.BlockedWrite blocked=new android.net.LocalSocket.BlockedWrite();
            android.net.LocalSocket.blockedWrite=blocked;
            Future<?> write=sender.submit(() -> {
                try { blockedWire.video(new byte[]{4,5,6}); }
                catch (IOException failure) { throw new RuntimeException(failure); }
            });
            check(blocked.entered.await(2,TimeUnit.SECONDS));
            endpoint.fallback(active,12);
            write.get(2,TimeUnit.SECONDS);
            check(!blockedWire.isWireless());
        } finally { sender.shutdownNow(); }
        System.out.println("Wireless endpoint: live-video warm-up, uninterrupted Bluetooth under blocked/overflowing candidates, profile authentication, receiver-confirmed quality and recovery passed");
    }

    static void blockedWarmupKeepsBluetooth() throws Exception {
        byte[] key=new byte[32], profile=new WirelessVideoProfile(1920,60,12000000).bytes();
        ByteArrayOutputStream classic=new ByteArrayOutputStream();
        BluetoothWire wire=new BluetoothWire(classic);
        try (WirelessVideoUpgrade endpoint=new WirelessVideoUpgrade(wire,key,p -> { throw new AssertionError("Unready candidate committed"); }); Socket socket=connect()) {
            DataInputStream input=new DataInputStream(socket.getInputStream());
            byte[] nonce=nonce(input);
            socket.getOutputStream().write(profile);
            socket.getOutputStream().write(WirelessUpgradeAuth.proof(key,"client",nonce,profile));
            check(Arrays.equals(input.readNBytes(32),WirelessUpgradeAuth.proof(key,"preview server",nonce,profile)));
            android.net.LocalSocket.BlockedWrite blocked=new android.net.LocalSocket.BlockedWrite();
            android.net.LocalSocket.blockedWrite=blocked;
            wire.video(new byte[]{1,2,3}); wire.videoFrameSent();
            check(blocked.entered.await(2,TimeUnit.SECONDS));
            // Overflow the candidate's bounded queue while its socket is stuck.
            // All video must still reach Classic without waiting for the socket.
            ExecutorService sender=Executors.newSingleThreadExecutor();
            try {
                sender.submit(() -> {
                    try { for(int i=0;i<300;i++) { wire.video(new byte[]{4,5,6}); wire.videoFrameSent(); } }
                    catch(IOException error) { throw new RuntimeException(error); }
                }).get(1,TimeUnit.SECONDS);
            } finally { sender.shutdownNow(); }
            check(!wire.isWireless());
            check(classic.size()==8+301*(8+13));
        }
        check(android.net.LocalSocket.blockedWrite==null);
    }

    static void staticScreenCanUpgrade() throws Exception {
        byte[] key=new byte[32], profile=new WirelessVideoProfile(1280,30,4000000).bytes();
        ByteArrayOutputStream classic=new ByteArrayOutputStream();
        BluetoothWire wire=new BluetoothWire(classic);
        byte[] frame={10,20,30,40}; wire.video(frame); wire.videoFrameSent(frame);
        CountDownLatch quality=new CountDownLatch(1);
        try(WirelessVideoUpgrade endpoint=new WirelessVideoUpgrade(wire,key,p -> { if(p!=null) quality.countDown(); }); Socket socket=connect()) {
            DataInputStream input=new DataInputStream(socket.getInputStream());
            byte[] nonce=nonce(input);
            DataOutputStream output=new DataOutputStream(socket.getOutputStream());
            output.write(profile); output.write(WirelessUpgradeAuth.proof(key,"client",nonce,profile)); output.flush();
            check(Arrays.equals(input.readNBytes(32),WirelessUpgradeAuth.proof(key,"preview server",nonce,profile)));
            // No new video is produced after candidate authentication.
            for(int i=0;i<3;i++) {
                check(previewLength(input)==frame.length);
                check(Arrays.equals(input.readNBytes(frame.length),frame));
                check(previewLength(input)==0);
                check(!wire.isWireless() && classic.size()>=17);
            }
            output.writeByte(1); output.flush();
            check(previewLength(input)==-1);
            byte[] response=input.readNBytes(48); check(response.length==48);
            check(java.nio.ByteBuffer.wrap(response).getLong()==4);
            output.writeByte(1); output.flush();
            check(quality.await(2,TimeUnit.SECONDS));
            check(wire.isWireless() && classic.size()>=17);
        }
    }
}
