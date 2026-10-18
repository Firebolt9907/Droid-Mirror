package app.droidmirror.bluetooth;

import android.content.Context;
import android.os.Binder;

/** Independent Shizuku service: task discovery never takes a mirror/display lease. */
public final class TaskUrlBridgeService extends ITaskUrlBridge.Stub {
    public TaskUrlBridgeService() {}
    public TaskUrlBridgeService(Context context) {}
    @Override public String readTask() {
        long identity = Binder.clearCallingIdentity();
        try { return TaskUrlReader.read(); }
        catch (Exception | LinkageError unavailable) { return ""; }
        finally { Binder.restoreCallingIdentity(identity); }
    }
    @Override public void destroy() { System.exit(0); }
}
