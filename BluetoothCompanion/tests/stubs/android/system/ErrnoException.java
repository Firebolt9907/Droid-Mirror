package android.system;
public final class ErrnoException extends Exception {
    public final int errno;
    public ErrnoException() { this("Test", 1); }
    public ErrnoException(String functionName, int errno) { super(functionName + " failed: errno " + errno); this.errno = errno; }
}
