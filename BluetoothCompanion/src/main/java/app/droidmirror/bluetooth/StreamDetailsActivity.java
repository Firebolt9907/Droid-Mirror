package app.droidmirror.bluetooth;

import android.app.Activity;
import android.app.PendingIntent;
import android.annotation.SuppressLint;
import android.content.BroadcastReceiver;
import android.content.Context;
import android.content.Intent;
import android.content.IntentFilter;
import android.os.Build;
import android.os.Bundle;
import android.os.Handler;
import android.os.Looper;
import android.os.SystemClock;
import android.widget.Button;
import android.widget.LinearLayout;
import android.widget.TextView;
import java.util.Locale;

/** Compact details when opening the stream notification on older Android versions. */
public final class StreamDetailsActivity extends Activity {
    private final Handler main = new Handler(Looper.getMainLooper());
    private String token;
    private long started;
    private TextView duration;
    private final Runnable tick = new Runnable() {
        @Override public void run() {
            long seconds = Math.max(0, SystemClock.elapsedRealtime() - started) / 1000;
            String time = seconds >= 3600
                ? String.format(Locale.getDefault(), "%d:%02d:%02d", seconds / 3600, seconds / 60 % 60, seconds % 60)
                : String.format(Locale.getDefault(), "%d:%02d", seconds / 60, seconds % 60);
            duration.setText(getString(R.string.stream_duration, time));
            main.postDelayed(this, 1000);
        }
    };
    private final BroadcastReceiver finished = new BroadcastReceiver() {
        @Override public void onReceive(Context context, Intent intent) {
            if (token.equals(intent.getStringExtra(StreamNotifications.TOKEN))) finish();
        }
    };
    @Override protected void onCreate(Bundle state) {
        super.onCreate(state);
        token = getIntent().getStringExtra(StreamNotifications.TOKEN);
        started = getIntent().getLongExtra(StreamNotifications.STARTED, 0);
        if (token == null || started <= 0) { finish(); return; }
        setTitle(R.string.stream_title);
        LinearLayout content = new LinearLayout(this);
        content.setOrientation(LinearLayout.VERTICAL);
        int padding = (int) (24 * getResources().getDisplayMetrics().density);
        content.setPadding(padding, padding, padding, padding);
        TextView peer = new TextView(this);
        peer.setText(getString(R.string.stream_destination, getIntent().getStringExtra(StreamNotifications.PEER)));
        peer.setTextSize(18); content.addView(peer);
        duration = new TextView(this); content.addView(duration);
        Button minimize = new Button(this); minimize.setText(R.string.stream_minimize);
        minimize.setOnClickListener(view -> {
            try { StreamNotifications.action(this, StreamNotifications.MINIMIZE, token).send(); }
            catch (PendingIntent.CanceledException ignored) {}
        });
        content.addView(minimize);
        Button disconnect = new Button(this); disconnect.setText(R.string.stream_disconnect);
        disconnect.setOnClickListener(view -> {
            try { StreamNotifications.action(this, StreamNotifications.DISCONNECT, token).send(); }
            catch (PendingIntent.CanceledException ignored) {}
            finish();
        });
        content.addView(disconnect); setContentView(content);
        registerFinished();
    }
    @SuppressLint("UnspecifiedRegisterReceiverFlag") // The legacy branch runs only below API 33, where these flags do not exist.
    private void registerFinished() {
        IntentFilter filter = new IntentFilter(StreamNotifications.FINISHED);
        if (Build.VERSION.SDK_INT >= 33) registerReceiver(finished, filter, Context.RECEIVER_NOT_EXPORTED);
        else registerReceiver(finished, filter);
    }
    @Override protected void onResume() {
        super.onResume();
        if (!isFinishing()) main.post(tick);
    }
    @Override protected void onPause() { main.removeCallbacks(tick); super.onPause(); }
    @Override protected void onDestroy() {
        main.removeCallbacks(tick);
        if (duration != null) unregisterReceiver(finished);
        super.onDestroy();
    }
}
