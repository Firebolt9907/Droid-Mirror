package android.system;
import java.io.FileDescriptor;
public final class Os {
    public static void shutdown(FileDescriptor fd,int how) throws ErrnoException {
        android.net.LocalServerSocket.shutdown(fd);
    }
}
