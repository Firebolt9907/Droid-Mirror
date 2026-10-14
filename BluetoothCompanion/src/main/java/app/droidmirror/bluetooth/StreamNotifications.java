package app.droidmirror.bluetooth;

import android.app.Notification;
import android.app.PendingIntent;
import android.content.Context;
import android.content.Intent;
import android.net.Uri;
import android.os.Build;
import android.os.Bundle;
import android.os.SystemClock;

/** One notification becomes a live update only while actual video is flowing. */
final class StreamNotifications {
    static final String DISCONNECT = "app.droidmirror.bluetooth.action.DISCONNECT_STREAM";
    static final String DISMISSED = "app.droidmirror.bluetooth.action.DISMISS_STREAM_UPDATE";
    static final String FINISHED = "app.droidmirror.bluetooth.action.STREAM_FINISHED";
    static final String TOKEN = "session", PEER = "peerName", STARTED = "startedElapsed";

    static PendingIntent action(Context context, String action, String token) {
        Intent intent = new Intent(context, CaptureService.class).setAction(action)
            .setData(Uri.parse("droidmirror://stream/" + token)).putExtra(TOKEN, token);
        return PendingIntent.getService(context, 0, intent, PendingIntent.FLAG_IMMUTABLE | PendingIntent.FLAG_UPDATE_CURRENT);
    }

    static Notification streaming(Context context, String token, String peer, long started, boolean dismissed) {
        Intent details = new Intent(context, StreamDetailsActivity.class)
            .setData(Uri.parse("droidmirror://stream/" + token))
            .putExtra(TOKEN, token).putExtra(PEER, peer).putExtra(STARTED, started);
        PendingIntent open = PendingIntent.getActivity(context, 0, details,
            PendingIntent.FLAG_IMMUTABLE | PendingIntent.FLAG_UPDATE_CURRENT);
        String text = context.getString(R.string.stream_destination, peer);
        Notification.Builder builder = new Notification.Builder(context, "capture")
            .setSmallIcon(R.drawable.ic_screen_share)
            .setContentTitle(context.getString(R.string.stream_title)).setContentText(text)
            .setStyle(new Notification.BigTextStyle().bigText(text))
            .setContentIntent(open).setOngoing(true).setOnlyAlertOnce(true)
            .setCategory(Notification.CATEGORY_STATUS).setVisibility(Notification.VISIBILITY_PRIVATE)
            .setWhen(System.currentTimeMillis() - Math.max(0, SystemClock.elapsedRealtime() - started))
            .setShowWhen(true).setUsesChronometer(true)
            .setDeleteIntent(action(context, DISMISSED, token))
            .addAction(new Notification.Action.Builder(null, context.getString(R.string.stream_disconnect),
                action(context, DISCONNECT, token)).build());
        if (Build.VERSION.SDK_INT >= 36) {
            // Public 36.1 extra: older Android 16 releases safely ignore the promotion request.
            // Using the documented extra also avoids calling a 36.1 method on base API 36.
            Bundle extras = new Bundle();
            extras.putBoolean("android.requestPromotedOngoing", !dismissed);
            builder.addExtras(extras);
        }
        return builder.build();
    }

    static void ended(Context context, String token) {
        action(context, DISCONNECT, token).cancel();
        action(context, DISMISSED, token).cancel();
        Intent details = new Intent(context, StreamDetailsActivity.class)
            .setData(Uri.parse("droidmirror://stream/" + token));
        PendingIntent open = PendingIntent.getActivity(context, 0, details,
            PendingIntent.FLAG_IMMUTABLE | PendingIntent.FLAG_NO_CREATE);
        if (open != null) open.cancel();
        context.sendBroadcast(new Intent(FINISHED).setPackage(context.getPackageName()).putExtra(TOKEN, token));
    }

    private StreamNotifications() {}
}
