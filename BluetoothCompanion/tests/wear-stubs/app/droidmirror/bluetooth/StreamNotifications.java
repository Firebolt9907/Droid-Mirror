package app.droidmirror.bluetooth;
import android.app.PendingIntent;
import android.content.Context;
public class StreamNotifications {
    public static final String DISCONNECT = "disconnect";
    public static PendingIntent last;
    public static PendingIntent action(Context context,String action,String session) { return last = new PendingIntent(); }
}
