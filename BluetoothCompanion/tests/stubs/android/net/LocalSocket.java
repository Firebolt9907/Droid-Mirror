package android.net;

import java.io.*;
import java.net.Socket;

/** JVM-only socket substitute for exercising the real upgrade protocol. */
public final class LocalSocket implements AutoCloseable {
    private final Socket socket;
    LocalSocket(Socket socket) { this.socket = socket; }
    public void setSoTimeout(int timeout) throws IOException { socket.setSoTimeout(timeout); }
    public InputStream getInputStream() throws IOException { return socket.getInputStream(); }
    public OutputStream getOutputStream() throws IOException { return socket.getOutputStream(); }
    public void close() throws IOException { socket.close(); }
}
