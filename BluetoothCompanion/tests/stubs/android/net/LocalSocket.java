package android.net;

import java.io.*;
import java.net.Socket;

/** JVM-only socket substitute for exercising the real upgrade protocol. */
public final class LocalSocket implements AutoCloseable {
    private final Socket socket;
    LocalSocket(Socket socket) { this.socket = socket; }
    public void setSoTimeout(int timeout) throws IOException { socket.setSoTimeout(timeout); }
    public InputStream getInputStream() throws IOException { return socket.getInputStream(); }
    public static final class BlockedWrite {
        public final java.util.concurrent.CountDownLatch entered = new java.util.concurrent.CountDownLatch(1);
        final java.util.concurrent.CountDownLatch shutdown = new java.util.concurrent.CountDownLatch(1);
    }
    public static volatile BlockedWrite blockedWrite;
    public OutputStream getOutputStream() throws IOException {
        OutputStream output=socket.getOutputStream();
        return new OutputStream() {
            public void write(int value) throws IOException { write(new byte[]{(byte)value},0,1); }
            public void write(byte[] bytes,int offset,int length) throws IOException {
                BlockedWrite blocked=blockedWrite;
                if (blocked!=null) {
                    blocked.entered.countDown();
                    try { blocked.shutdown.await(); }
                    catch (InterruptedException error) { Thread.currentThread().interrupt(); throw new IOException(error); }
                    throw new IOException("Native ADB write interrupted by shutdown");
                }
                output.write(bytes,offset,length);
            }
        };
    }
    public void shutdownOutput() throws IOException {
        BlockedWrite blocked=blockedWrite;
        if (blocked!=null) { blockedWrite=null; blocked.shutdown.countDown(); }
        socket.shutdownOutput();
    }
    public void shutdownInput() throws IOException { socket.shutdownInput(); }
    public void close() throws IOException { socket.close(); }
}
