package app.droidmirror.bluetooth;

import android.app.PendingIntent;
import android.content.Context;

/** Uses the exact same token-scoped, graceful disconnect as the phone notification. */
public final class WearSessionAccess {
    private static String token = "";
    private static PendingIntent stop;
    public static synchronized void streaming(Context context, String session) {
        if (token.equals(session)) return;
        token = session;
        stop = StreamNotifications.action(context, StreamNotifications.DISCONNECT, session);
        app.droidmirror.bluetooth.bridge.WearPhoneBridge.refresh(context);
    }
    public static synchronized void ended(String session) {
        if (token.equals(session)) { token = ""; stop = null; }
    }
    public static synchronized String token() { return token; }
    public static synchronized boolean stop(String session) {
        if (!token.equals(session) || stop == null) return false;
        try { stop.send(); return true; }
        catch (PendingIntent.CanceledException error) { return false; }
    }
    private WearSessionAccess() {}
}
