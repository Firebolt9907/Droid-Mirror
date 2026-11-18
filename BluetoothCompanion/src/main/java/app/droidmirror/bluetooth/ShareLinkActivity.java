package app.droidmirror.bluetooth;

import android.app.Activity;
import android.os.Bundle;
import android.os.Handler;
import android.os.Looper;
import android.content.Intent;
import android.widget.TextView;
import app.droidmirror.bluetooth.bridge.BridgeRuntime;

/** Foreground share UI never reads the clipboard and never accepts files. */
public final class ShareLinkActivity extends Activity {
    private final Handler handler = new Handler(Looper.getMainLooper());
    private TextView status;
    private String request;
    @Override public void onCreate(Bundle state) {
        super.onCreate(state);
        status = new TextView(this);
        status.setPadding(40, 40, 40, 40);
        setContentView(status);
        if (state != null) { status.setText("Sharing was interrupted. Share the link again to retry."); return; }
        Intent intent = getIntent();
        if (!Intent.ACTION_SEND.equals(intent.getAction()) || !"text/plain".equals(intent.getType())
                || intent.hasExtra(Intent.EXTRA_STREAM)) {
            status.setText("Share one HTTP or HTTPS link to DroidMirror."); return;
        }
        CharSequence sharedText = intent.getCharSequenceExtra(Intent.EXTRA_TEXT);
        String url = SharedLink.extract(sharedText == null ? null : sharedText.toString());
        if (url == null) { status.setText("Share one HTTP or HTTPS link to DroidMirror."); return; }
        BridgeRuntime runtime = BridgeRuntime.Companion.getLive();
        if (runtime == null) { status.setText("Open DroidMirror and enable the background bridge, then share the link again."); return; }
        java.util.List<String> computers = runtime.linkComputers();
        if (computers.isEmpty()) { status.setText("No computer is connected. Keep DroidMirror running on your computer and nearby, then share again."); return; }
        if (computers.size() == 1) { send(runtime, url, computers.get(0)); return; }
        // Two connected computers: the user picks where the link opens.
        String[] names = new String[computers.size()];
        for (int i = 0; i < names.length; i++) names[i] = name(computers.get(i));
        status.setText("Choose a computer…");
        new android.app.AlertDialog.Builder(this).setTitle("Open link on")
            .setItems(names, (dialog, which) -> send(runtime, url, computers.get(which)))
            .setOnCancelListener(dialog -> finish()).show();
    }
    private String name(String address) {
        try {
            String value = getSystemService(android.bluetooth.BluetoothManager.class).getAdapter().getRemoteDevice(address).getName();
            return value == null ? address : value;
        } catch (RuntimeException unavailable) { return address; }
    }
    private void send(BridgeRuntime runtime, String url, String computer) {
        String label = name(computer);
        status.setText("Opening link on " + label + "…");
        request = runtime.shareLink(url, computer, success -> {
            if (isFinishing() || isDestroyed()) return;
            handler.removeCallbacksAndMessages(null);
            status.setText(success ? "Opened in " + label + "’s default browser." : "Could not open the link. Check that " + label + " is nearby and DroidMirror is running.");
        });
        if (request != null) handler.postDelayed(() -> {
            runtime.cancelSharedLink(request);
            status.setText(label + " did not confirm opening the link. Check the connection before retrying.");
        }, 15000);
    }
    @Override protected void onDestroy() {
        handler.removeCallbacksAndMessages(null);
        BridgeRuntime runtime = BridgeRuntime.Companion.getLive();
        if (runtime != null && request != null) runtime.cancelSharedLink(request);
        super.onDestroy();
    }
}
