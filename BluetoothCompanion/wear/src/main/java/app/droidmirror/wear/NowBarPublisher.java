package app.droidmirror.wear;

import android.Manifest;
import android.app.NotificationChannel;
import android.app.NotificationManager;
import android.app.PendingIntent;
import android.content.Context;
import android.content.Intent;
import android.content.pm.PackageManager;
import android.os.Build;
import androidx.core.app.NotificationCompat;
import androidx.wear.ongoing.OngoingActivity;
import androidx.wear.ongoing.Status;
import app.droidmirror.wearprotocol.WearProtocol;

/** Same Ongoing Activity approach as apple-tv-app's NowBarPublisher. */
final class NowBarPublisher {
    private static final int ID = 80;
    private static final String CHANNEL = "mirror-privacy";
    static final String STOP = "app.droidmirror.wear.STOP";
    static void update(Context context) {
        String session = WatchState.session();
        if (session.isEmpty()) { clear(context); return; }
        if (Build.VERSION.SDK_INT >= 33 && context.checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) != PackageManager.PERMISSION_GRANTED) return;
        NotificationManager manager = context.getSystemService(NotificationManager.class);
        manager.createNotificationChannel(new NotificationChannel(CHANNEL, "Mirroring privacy control", NotificationManager.IMPORTANCE_LOW));
        PendingIntent open = PendingIntent.getActivity(context, 0, new Intent(context, MainActivity.class), PendingIntent.FLAG_IMMUTABLE | PendingIntent.FLAG_UPDATE_CURRENT);
        PendingIntent stop = PendingIntent.getActivity(context, 1, new Intent(context, MainActivity.class).setAction(STOP)
            .putExtra("session",session).putExtra("lease",WatchState.state.optString("lease")), PendingIntent.FLAG_IMMUTABLE | PendingIntent.FLAG_UPDATE_CURRENT);
        NotificationCompat.Builder builder = new NotificationCompat.Builder(context, CHANNEL)
            .setSmallIcon(R.drawable.ic_privacy).setContentTitle("Phone is being mirrored")
            .setContentText("Tap for privacy stop").setContentIntent(open)
            .setOngoing(true).setOnlyAlertOnce(true).setLocalOnly(true)
            .setVisibility(NotificationCompat.VISIBILITY_PRIVATE).setCategory(NotificationCompat.CATEGORY_STATUS)
            .setTimeoutAfter(WearProtocol.LEASE_MS)
            .addAction(R.drawable.ic_privacy, "End mirroring", stop);
        new OngoingActivity.Builder(context, ID, builder).setStaticIcon(R.drawable.ic_privacy)
            .setTouchIntent(open).setStatus(new Status.Builder().addTemplate("Phone mirroring").build())
            .build().apply(context);
        manager.notify(ID,builder.build());
    }
    static void clear(Context ctx) { ctx.getSystemService(NotificationManager.class).cancel(ID); }
    private NowBarPublisher() {}
}
