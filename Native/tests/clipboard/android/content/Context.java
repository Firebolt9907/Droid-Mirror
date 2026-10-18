package android.content;

/** JVM-only file clipboard harness; never packaged. */
public final class Context {
    private final java.io.File cache;
    public Context(java.io.File cache) { this.cache = cache; }
    public java.io.File getCacheDir() { return cache; }
    public String getPackageName() { return "app.droidmirror.bluetooth"; }
    public void grantUriPermission(String owner, android.net.Uri uri, int flags) {}
    public void revokeUriPermission(android.net.Uri uri, int flags) {}
}
