package app.droidmirror.bluetooth;

import android.net.LocalServerSocket;
import android.net.LocalSocket;
import java.io.*;
import java.security.MessageDigest;
import java.security.SecureRandom;

/** Independent audio lane inside paired QUIC or authorized wireless ADB. */
final class WirelessAudioUpgrade implements AutoCloseable {
    interface Session {
        boolean ready();
        boolean start(OutputStream output);
        void stop();
    }
    private final LocalServerSocket listener;
    private final Session session;
    private final byte[] key;
    private final Thread worker;
    private volatile LocalSocket candidate;
    private volatile boolean closed;
    WirelessAudioUpgrade(byte[] pairing, Session session) throws IOException {
        this.session=session; key=pairing.clone(); java.util.Arrays.fill(pairing,(byte)0);
        listener=new LocalServerSocket("droidmirror_audio_upgrade");
        worker=new Thread(this::listen,"WirelessAudioEndpoint"); worker.start();
    }
    private void listen() {
        try {
            while (!closed) {
                LocalSocket socket=listener.accept(); candidate=socket;
                boolean started=false;
                try {
                    if (closed || !session.ready()) continue;
                    socket.setSoTimeout(2000);
                    DataInputStream input=new DataInputStream(socket.getInputStream());
                    OutputStream output=socket.getOutputStream();
                    byte[] nonce=new byte[32]; new SecureRandom().nextBytes(nonce);
                    output.write("DMAUDIO1".getBytes(java.nio.charset.StandardCharsets.US_ASCII)); output.write(nonce); output.flush();
                    byte[] proof=new byte[32]; input.readFully(proof);
                    if (!MessageDigest.isEqual(proof,WirelessUpgradeAuth.proof(key,"audio client",nonce,new byte[0]))) continue;
                    output.write(WirelessUpgradeAuth.proof(key,"audio server",nonce,new byte[0])); output.flush();
                    if (input.readUnsignedByte()!=1 || closed || !session.ready()) continue;
                    // Android LocalSocket timeout uses plain IOException/EAGAIN,
                    // not java.net.SocketTimeoutException. This direction is
                    // intentionally idle during playback; only EOF ends it.
                    socket.setSoTimeout(0);
                    output.write(BluetoothWire.MAGIC); output.flush();
                    started=session.start(output);
                    if (!started) throw new IOException("Audio capture unavailable");
                    if (input.read()!=-1) throw new IOException("Unexpected audio command");
                } catch (IOException error) {
                    if (!closed) android.util.Log.i("DroidMirrorAudio","Independent audio lane ended: "+error.getMessage());
                } finally {
                    abort(socket);
                    if (started) session.stop();
                    if (candidate==socket) candidate=null;
                }
            }
        } catch (IOException stopped) { }
        finally { java.util.Arrays.fill(key,(byte)0); }
    }
    private static void abort(LocalSocket socket) {
        if (socket==null) return;
        try { socket.shutdownOutput(); } catch(IOException ignored) {}
        try { socket.shutdownInput(); } catch(IOException ignored) {}
        try { socket.close(); } catch(IOException ignored) {}
    }
    void disconnect() { abort(candidate); }
    @Override public void close() {
        closed=true; disconnect();
        try { android.system.Os.shutdown(listener.getFileDescriptor(),android.system.OsConstants.SHUT_RDWR); }
        catch(android.system.ErrnoException ignored) {}
        try { listener.close(); } catch(IOException ignored) {}
    }
}
