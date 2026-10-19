package app.droidmirror.bluetooth;

import android.content.ContentResolver;
import android.content.Context;
import android.content.IContentProvider;
import android.os.Binder;
import com.genymobile.scrcpy.FakeContext;
import com.genymobile.scrcpy.wrappers.ServiceManager;
import java.util.ArrayList;

/** Shell resolver with unstable-provider support and scoped external provider leases. */
final class ClipboardResolver extends ContentResolver implements AutoCloseable {
    private static final class Lease {
        final String name; final Binder token = new Binder();
        Lease(String name) { this.name = name; }
    }
    private final ArrayList<Lease> leases = new ArrayList<>();
    ClipboardResolver() { super(FakeContext.get()); }
    @SuppressWarnings("unused")
    protected IContentProvider acquireProvider(Context context, String name) {
        Lease lease = new Lease(name);
        IContentProvider provider = ServiceManager.getActivityManager().getContentProviderExternal(name, lease.token);
        if (provider != null) leases.add(lease);
        return provider;
    }
    @SuppressWarnings("unused")
    protected IContentProvider acquireUnstableProvider(Context context, String name) { return acquireProvider(context, name); }
    @SuppressWarnings("unused")
    public boolean releaseProvider(IContentProvider provider) { return true; }
    @SuppressWarnings("unused")
    public boolean releaseUnstableProvider(IContentProvider provider) { return true; }
    @SuppressWarnings("unused")
    public void unstableProviderDied(IContentProvider provider) {}
    @Override public void close() {
        // The existing scrcpy wrapper exposes this operation at package scope.
        try {
            Object activity = ServiceManager.getActivityManager();
            java.lang.reflect.Method release = activity.getClass().getDeclaredMethod("removeContentProviderExternal", String.class, android.os.IBinder.class);
            release.setAccessible(true);
            for (Lease lease : leases) release.invoke(activity, lease.name, lease.token);
        } catch (ReflectiveOperationException ignored) {
            // Process teardown also releases these Binder-owned leases.
        } finally { leases.clear(); }
    }
}
