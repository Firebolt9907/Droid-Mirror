package app.droidmirror.bluetooth;

import android.Manifest;
import android.app.Notification;
import android.app.NotificationChannel;
import android.app.NotificationManager;
import android.content.Context;
import android.content.pm.PackageManager;
import android.os.Build;
import java.io.IOException;
import java.util.concurrent.TimeUnit;

final class SessionAudit {
    static final String TITLE = "Phone was used remotely";
    static final String TEXT = "Your DroidMirror mirroring session ended.";
    static boolean phone(Context context) {
        if (Build.VERSION.SDK_INT >= 33 && context.checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) != PackageManager.PERMISSION_GRANTED) return false;
        NotificationManager notifications = context.getSystemService(NotificationManager.class);
        notifications.createNotificationChannel(new NotificationChannel("remote-use", "Remote use history", NotificationManager.IMPORTANCE_DEFAULT));
        notifications.notify(2, new Notification.Builder(context, "remote-use").setSmallIcon(android.R.drawable.ic_menu_view)
            .setContentTitle(TITLE).setContentText(TEXT).setAutoCancel(true).build());
        return true;
    }
    static boolean shell() {
        java.lang.Process command = null;
        try {
            // Structured argv, no shell interpolation. The shell's notification survives app force-stop.
            command = new ProcessBuilder("/system/bin/cmd", "notification", "post", "-t", TITLE,
                "DroidMirror.remote-use", TEXT).redirectErrorStream(true).start();
            return command.waitFor(1000, TimeUnit.MILLISECONDS) && command.exitValue() == 0;
        } catch (IOException | InterruptedException error) {
            if (error instanceof InterruptedException) Thread.currentThread().interrupt();
            return false;
        } finally { if (command != null && command.isAlive()) command.destroyForcibly(); }
    }
}
