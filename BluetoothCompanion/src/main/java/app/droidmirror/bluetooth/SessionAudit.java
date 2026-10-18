package app.droidmirror.bluetooth;

import android.Manifest;
import android.app.Notification;
import android.app.NotificationChannel;
import android.app.NotificationManager;
import android.content.Context;
import android.content.pm.PackageManager;
import android.os.Build;

final class SessionAudit {
    static final String TITLE = "Phone Mirroring";
    static final String COMPUTER_NAME = "computerName";
    static String text(String computerName) {
        return "Phone was used from " + (computerName == null || computerName.trim().isEmpty() ? "Mac" : computerName.trim());
    }
    static String computerName(Context context, String peer) {
        try {
            android.bluetooth.BluetoothManager manager = context.getSystemService(android.bluetooth.BluetoothManager.class);
            return manager.getAdapter().getRemoteDevice(peer).getName();
        } catch (SecurityException | IllegalArgumentException | NullPointerException unavailable) { return null; }
    }
    static void clear(Context context) {
        context.stopService(new android.content.Intent(context, RemoteUseWarningService.class));
        context.getSystemService(NotificationManager.class).cancel(2);
    }
    static boolean phone(Context context, String computerName) {
        if (Build.VERSION.SDK_INT >= 33 && context.checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) != PackageManager.PERMISSION_GRANTED) return false;
        try {
            context.startForegroundService(new android.content.Intent(context, RemoteUseWarningService.class).putExtra(COMPUTER_NAME, computerName));
            return true;
        } catch (RuntimeException unavailable) {
            NotificationManager notifications = context.getSystemService(NotificationManager.class);
            notifications.createNotificationChannel(new NotificationChannel("remote-use", "Remote use history", NotificationManager.IMPORTANCE_DEFAULT));
            notifications.notify(2, new Notification.Builder(context, "remote-use").setSmallIcon(R.drawable.ic_screen_share)
                .setContentTitle(TITLE).setContentText(text(computerName)).setAutoCancel(true).build());
            return false;
        }
    }
    static boolean shell(String computerName) {
        return com.genymobile.scrcpy.RemoteUseWarning.launch(computerName);
    }
}
