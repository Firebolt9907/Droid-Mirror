package app.droidmirror.bluetooth;

import android.content.BroadcastReceiver;
import android.content.Context;
import android.content.Intent;

public final class ReadyReceiver extends BroadcastReceiver {
    @Override public void onReceive(Context context, Intent intent) {
        if (Intent.ACTION_BOOT_COMPLETED.equals(intent.getAction())) CaptureService.enableIfConfigured(context);
    }
}
