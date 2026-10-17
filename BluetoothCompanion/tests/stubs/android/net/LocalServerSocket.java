package android.net;

import java.io.IOException;
import java.net.*;

/** Maps the Android abstract endpoint to a private ephemeral loopback port in tests. */
public final class LocalServerSocket implements AutoCloseable {
    public static volatile int testPort;
    private final ServerSocket server;
    private final java.io.FileDescriptor descriptor=new java.io.FileDescriptor();
    private static final java.util.concurrent.ConcurrentHashMap<java.io.FileDescriptor,ServerSocket> sockets=new java.util.concurrent.ConcurrentHashMap<>();
    public LocalServerSocket(String name) throws IOException {
        server = new ServerSocket(0,1,InetAddress.getLoopbackAddress());
        testPort = server.getLocalPort();
        sockets.put(descriptor,server);
    }
    public LocalSocket accept() throws IOException { return new LocalSocket(server.accept()); }
    public java.io.FileDescriptor getFileDescriptor() { return descriptor; }
    public static void shutdown(java.io.FileDescriptor descriptor) throws android.system.ErrnoException {
        try { ServerSocket socket=sockets.get(descriptor); if(socket!=null) socket.close(); }
        catch(IOException failed) { throw new android.system.ErrnoException(); }
    }
    public void close() throws IOException { sockets.remove(descriptor); server.close(); }
}
