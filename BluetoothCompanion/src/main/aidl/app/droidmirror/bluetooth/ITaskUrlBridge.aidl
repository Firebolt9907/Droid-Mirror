package app.droidmirror.bluetooth;
import android.app.PendingIntent;

interface ITaskUrlBridge {
    String readTask() = 1;
    boolean openBrowser(String url) = 2;
    String readHandoffDiagnostics() = 3;
    boolean openNotification(in PendingIntent intent) = 4;
    boolean openLauncher(String component) = 5;
    void destroy() = 16777114;
}
