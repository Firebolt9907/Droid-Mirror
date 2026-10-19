package app.droidmirror.bluetooth;
import java.io.*;
import java.net.*;
import java.util.*;
import java.util.concurrent.*;
import java.util.concurrent.atomic.*;
public final class WirelessAudioUpgradeTest {
    static void check(boolean ok) { if(!ok) throw new AssertionError(); }
    static Socket connect() throws IOException {
        Socket s=new Socket(InetAddress.getLoopbackAddress(),android.net.LocalServerSocket.testPort); s.setSoTimeout(2000); return s;
    }
    static final class Session implements WirelessAudioUpgrade.Session {
        volatile boolean ready=true;
        final AtomicInteger starts=new AtomicInteger(),stops=new AtomicInteger();
        public boolean ready() { return ready; }
        public boolean start(OutputStream output) {
            starts.incrementAndGet();
            try { output.write(new byte[]{7,0,0,0,12,0,0,0,0,0,0,0,42,1,2,3,4}); output.flush(); return true; }
            catch(IOException e) { return false; }
        }
        public void stop() { stops.incrementAndGet(); }
    }
    public static void main(String[] args) throws Exception {
        byte[] key=new byte[32]; Arrays.fill(key,(byte)42);
        Session session=new Session();
        if (args.length==2) {
            try(WirelessAudioUpgrade endpoint=new WirelessAudioUpgrade(key.clone(),session)) {
                java.nio.file.Path folder=java.nio.file.Path.of(args[1]);
                java.nio.file.Files.writeString(folder.resolve("audio-port"),Integer.toString(android.net.LocalServerSocket.testPort));
                long until=System.nanoTime()+10_000_000_000L;
                while(!java.nio.file.Files.exists(folder.resolve("audio-done")) && System.nanoTime()<until) Thread.sleep(20);
            }
            check(session.starts.get()==3 && session.stops.get()==3); return;
        }

        try(WirelessAudioUpgrade endpoint=new WirelessAudioUpgrade(key.clone(),session)) {
            try(Socket wrong=connect()) {
                DataInputStream in=new DataInputStream(wrong.getInputStream()); check(in.readNBytes(40).length==40);
                wrong.getOutputStream().write(new byte[32]); check(in.read()==-1); check(session.starts.get()==0 && session.stops.get()==0);
            }
            try(Socket good=connect()) {
                DataInputStream in=new DataInputStream(good.getInputStream());
                check(Arrays.equals(in.readNBytes(8),"DMAUDIO1".getBytes())); byte[] nonce=in.readNBytes(32);
                good.getOutputStream().write(WirelessUpgradeAuth.proof(key,"audio client",nonce,new byte[0]));
                check(Arrays.equals(in.readNBytes(32),WirelessUpgradeAuth.proof(key,"audio server",nonce,new byte[0])));
                check(session.starts.get()==0); // Client acceptance required before capture/muting.
                good.getOutputStream().write(1);
                check(Arrays.equals(in.readNBytes(8),BluetoothWire.MAGIC));
                check(in.readByte()==7 && in.readInt()==12 && in.readNBytes(12).length==12);
                check(session.starts.get()==1);
                Thread.sleep(800); // Idle reverse control is healthy, not EOF.
                check(session.stops.get()==0 && session.starts.get()==1);
            }
            long deadline=System.nanoTime()+2_000_000_000L;
            while(session.stops.get()==0 && System.nanoTime()<deadline) Thread.sleep(5);
            check(session.stops.get()==1);
            session.ready=false;
            try(Socket offline=connect()) { check(offline.getInputStream().read()==-1); }
            check(session.starts.get()==1);
        }
        System.out.println("Independent audio endpoint: paired fresh proof, mutual authentication, capture acceptance, idle Android socket semantics, EOF cleanup and Wi-Fi-only admission passed");
    }
}
