package app.droidmirror.bluetooth;

import android.app.Notification;
import android.app.NotificationChannel;
import android.app.NotificationManager;
import android.app.PendingIntent;
import android.content.Context;
import android.content.Intent;
import android.net.Uri;
import android.os.Build;
import android.os.Bundle;
import android.provider.Settings;

/** One notification becomes a live update only while actual video is flowing. */
final class StreamNotifications {
    private static final String CHANNEL = "active-mirroring";
    static final String DISCONNECT = "app.droidmirror.bluetooth.action.DISCONNECT_STREAM";
    static final String MINIMIZE = "app.droidmirror.bluetooth.action.MINIMIZE_STREAM";
    static final String DISMISSED = "app.droidmirror.bluetooth.action.DISMISS_STREAM_UPDATE";
    static final String FINISHED = "app.droidmirror.bluetooth.action.STREAM_FINISHED";
    static final String TOKEN = "session", STARTED = "startedElapsed";
    static final String TITLE_TEXT = "Phone Mirroring";

    static PendingIntent action(Context context, String action, String token) {
        Intent intent = new Intent(context, token.startsWith("adb-") ? AdbStreamService.class : CaptureService.class).setAction(action)
            .setData(Uri.parse("droidmirror://stream/" + token)).putExtra(TOKEN, token);
        return PendingIntent.getService(context, 0, intent, PendingIntent.FLAG_IMMUTABLE | PendingIntent.FLAG_UPDATE_CURRENT);
    }

    static Notification streaming(Context context, String token, long started, boolean dismissed) {
        context.getSystemService(NotificationManager.class).createNotificationChannel(
            new NotificationChannel(CHANNEL, "Phone Mirroring", NotificationManager.IMPORTANCE_LOW));
        Intent details = new Intent(context, StreamDetailsActivity.class)
            .setData(Uri.parse("droidmirror://stream/" + token))
            .putExtra(TOKEN, token).putExtra(STARTED, started);
        PendingIntent open = PendingIntent.getActivity(context, 0, details,
            PendingIntent.FLAG_IMMUTABLE | PendingIntent.FLAG_UPDATE_CURRENT);
        String text = mirroringText(context);
        Notification.Builder builder = new Notification.Builder(context, CHANNEL)
            .setSmallIcon(R.drawable.ic_screen_share)
            .setContentTitle(TITLE_TEXT)
            .setContentText(text)
            .setContentIntent(open).setOngoing(true).setOnlyAlertOnce(true)
            .setCategory(Notification.CATEGORY_STATUS).setVisibility(Notification.VISIBILITY_PRIVATE)
            .setShowWhen(false)
            .setDeleteIntent(action(context, DISMISSED, token))
            .addAction(new Notification.Action.Builder(null, context.getString(R.string.stream_minimize),
                action(context, MINIMIZE, token)).build())
            .addAction(new Notification.Action.Builder(null, context.getString(R.string.stream_disconnect),
                action(context, DISCONNECT, token)).build());
        if (Build.VERSION.SDK_INT >= 36) {
            builder.setShortCriticalText(context.getString(R.string.stream_short_status));
            // Public 36.1 extra: older Android 16 releases safely ignore the promotion request.
            // Using the documented extra also avoids calling a 36.1 method on base API 36.
            Bundle extras = new Bundle();
            extras.putBoolean("android.requestPromotedOngoing", !dismissed);
            builder.addExtras(extras);
        }
        return builder.build();
    }

    static String mirroringText(Context context) {
        String name = null;
        try {
            name = Settings.Global.getString(context.getContentResolver(), "device_name");
        } catch (SecurityException ignored) {
            // Some devices restrict access to the user-defined device name.
        }
        if (name == null || name.trim().isEmpty()) name = Build.MODEL;
        if (name == null || name.trim().isEmpty()) name = context.getString(R.string.stream_phone_fallback);
        return context.getString(R.string.stream_phone, name.trim());
    }

    static void ended(Context context, String token) {
        action(context, MINIMIZE, token).cancel();
        action(context, DISCONNECT, token).cancel();
        action(context, DISMISSED, token).cancel();
        Intent details = new Intent(context, StreamDetailsActivity.class)
            .setData(Uri.parse("droidmirror://stream/" + token));
        PendingIntent open = PendingIntent.getActivity(context, 0, details,
            PendingIntent.FLAG_IMMUTABLE | PendingIntent.FLAG_NO_CREATE);
        if (open != null) open.cancel();
        context.sendBroadcast(new Intent(FINISHED).setPackage(context.getPackageName()).putExtra(TOKEN, token));
    }

    /** Best effort over the existing authenticated BLE link; never reconnect or stop capture. */
    static void minimizeOnMac() {
        app.droidmirror.bluetooth.bridge.BridgeRuntime runtime =
            app.droidmirror.bluetooth.bridge.BridgeRuntime.Companion.getLive();
        if (runtime != null) {
            org.json.JSONObject event = new org.json.JSONObject();
            try { event.put("type", "minimizeMirror"); }
            catch (org.json.JSONException impossible) { return; }
            runtime.sendEvent(event);
        }
    }

    private StreamNotifications() {}
}
