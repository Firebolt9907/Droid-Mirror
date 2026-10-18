package android.system;
import java.io.FileDescriptor;
public final class Os {
    public interface MockHandler {
        FileDescriptor open(String path, int flags, int mode) throws Exception;
        int write(FileDescriptor fd, byte[] bytes, int byteOffset, int byteCount) throws Exception;
        void close(FileDescriptor fd) throws Exception;
    }
    public static MockHandler mockHandler;

    public static void shutdown(FileDescriptor fd, int how) throws ErrnoException {
        android.net.LocalServerSocket.shutdown(fd);
    }

    public static FileDescriptor open(String path, int flags, int mode) throws ErrnoException {
        if (mockHandler != null) {
            try { return mockHandler.open(path, flags, mode); }
            catch (ErrnoException e) { throw e; }
            catch (Exception e) { throw new ErrnoException("open", 1); }
        }
        throw new ErrnoException("open", 2);
    }

    public static int write(FileDescriptor fd, byte[] bytes, int byteOffset, int byteCount) throws ErrnoException {
        if (mockHandler != null) {
            try { return mockHandler.write(fd, bytes, byteOffset, byteCount); }
            catch (ErrnoException e) { throw e; }
            catch (Exception e) { throw new ErrnoException("write", 5); }
        }
        return byteCount;
    }

    public static void close(FileDescriptor fd) throws ErrnoException {
        if (mockHandler != null) {
            try { mockHandler.close(fd); return; }
            catch (ErrnoException e) { throw e; }
            catch (Exception e) { throw new ErrnoException("close", 9); }
        }
    }
}
