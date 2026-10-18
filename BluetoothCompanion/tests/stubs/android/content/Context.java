package android.content;
/** Minimal JVM context for persistence migration tests; never packaged. */
public abstract class Context {
    public static final int MODE_PRIVATE = 0;
    public abstract SharedPreferences getSharedPreferences(String name, int mode);
}
