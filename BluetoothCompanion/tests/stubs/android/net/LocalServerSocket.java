package android.net;

import java.io.IOException;
import java.net.*;

/** Maps the Android abstract endpoint to a private ephemeral loopback port in tests. */
public final class LocalServerSocket implements AutoCloseable {
    public static volatile int testPort;
    private final ServerSocket server;
    public LocalServerSocket(String name) throws IOException {
        server = new ServerSocket(0,1,InetAddress.getLoopbackAddress());
        testPort = server.getLocalPort();
    }
    public LocalSocket accept() throws IOException { return new LocalSocket(server.accept()); }
    public void close() throws IOException { server.close(); }
}
