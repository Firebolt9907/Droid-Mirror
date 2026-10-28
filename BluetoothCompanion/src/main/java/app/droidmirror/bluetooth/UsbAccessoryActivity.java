package app.droidmirror.bluetooth;

import android.app.Activity;
import android.os.Bundle;

/** Android's accessory chooser grants USB permission before launching this activity. */
public final class UsbAccessoryActivity extends Activity {
    @Override public void onCreate(Bundle state) {
        super.onCreate(state);
        CaptureService.enableIfConfigured(this);
        finish();
    }
}
