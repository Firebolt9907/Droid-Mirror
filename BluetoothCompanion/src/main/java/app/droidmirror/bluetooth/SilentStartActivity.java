package app.droidmirror.bluetooth;

import android.app.Activity;
import android.os.Bundle;
import android.util.Log;

/** Transparent foreground entry for automation allowed to launch activities. */
public final class SilentStartActivity extends Activity {
    @Override protected void onCreate(Bundle state) {
        super.onCreate(state);
        if (!AutomationReceiver.ACTION_START_READY.equals(getIntent().getAction())) finish();
    }

    @Override protected void onResume() {
        super.onResume();
        if (!isFinishing()) {
            Log.i("DroidMirrorReady", CaptureService.enableIfConfigured(this).name());
            finish();
        }
        overridePendingTransition(0, 0);
    }
}
