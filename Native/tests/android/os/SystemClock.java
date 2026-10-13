package android.os;
/** JVM-only monotonic clock for fragment tests. */
public final class SystemClock {
    public static long elapsedRealtime() { return System.nanoTime() / 1000000; }
}
