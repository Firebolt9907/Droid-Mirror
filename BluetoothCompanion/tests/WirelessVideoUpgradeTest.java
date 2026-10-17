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
    static byte[] nonce(DataInputStream input) throws IOException {
        check(Arrays.equals(input.readNBytes(8),"DMWIFI03".getBytes(java.nio.charset.StandardCharsets.US_ASCII)));
        byte[] nonce=input.readNBytes(32); check(nonce.length==32); return nonce;
    }
    static byte[] authenticate(Socket socket, byte[] key, byte[] profile) throws Exception {
        DataInputStream input=new DataInputStream(socket.getInputStream());
        byte[] nonce=nonce(input);
        DataOutputStream output=new DataOutputStream(socket.getOutputStream());
        output.write(profile); output.write(WirelessUpgradeAuth.proof(key,"client",nonce,profile)); output.flush();
        byte[] response=input.readNBytes(48); check(response.length==48);
        check(java.nio.ByteBuffer.wrap(response).getLong()>=3);
        byte[] authenticated=java.nio.ByteBuffer.allocate(20).put(profile).put(response,0,8).array();
        check(Arrays.equals(Arrays.copyOfRange(response,8,40),WirelessUpgradeAuth.proof(key,"server",nonce,authenticated)));
        check(Arrays.equals(Arrays.copyOfRange(response,40,48),BluetoothWire.MAGIC));
        return nonce;
    }
    public static void main(String[] args) throws Exception {
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
                sessionNonce=authenticate(good,key,profile);
                check(!quality.await(40,TimeUnit.MILLISECONDS));
                good.getOutputStream().write(1); good.getOutputStream().flush();
                check(quality.await(2,TimeUnit.SECONDS));
                wire.video(new byte[]{4,5,6});
                DataInputStream received=new DataInputStream(good.getInputStream());
                int type=received.readUnsignedByte(), length=received.readInt();
                if (type==1) { check(length==1 && received.readByte()==6); type=received.readUnsignedByte(); length=received.readInt(); }
                check(type==0 && length==3);
                check(Arrays.equals(received.readNBytes(3),new byte[]{4,5,6}));
            }
            // The socket disappearing alone must not start Bluetooth video.
            Thread.sleep(30); check(wire.isWireless());
            endpoint.fallback(new byte[32],5); check(wire.isWireless());
            endpoint.fallback(sessionNonce,5); // Authenticated BLE request after a partial frame.
            check(restored.await(2,TimeUnit.SECONDS));
            long until=System.nanoTime()+2_000_000_000L;
            while (wire.isWireless() && System.nanoTime()<until) Thread.sleep(5);
            check(!wire.isWireless());
            try (Socket again=connect()) {
                authenticate(again,key,profile);
                endpoint.fallback(sessionNonce,6); check(wire.isWireless()); // Stale connection signal.
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
            byte[] failedNonce=authenticate(socket,key,profile); socket.getOutputStream().write(0);
            check(socket.getInputStream().read()==-1);
            endpoint.fallback(failedNonce,3);
            long until=System.nanoTime()+2_000_000_000L;
            while (failedWire.isWireless() && System.nanoTime()<until) Thread.sleep(5);
            check(!failedWire.isWireless());
        }
        System.out.println("Wireless endpoint: profile authentication, receiver-confirmed quality, bad profile rejection and failed-confirmation teardown passed");
    }
}
