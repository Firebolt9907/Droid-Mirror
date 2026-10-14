package app.droidmirror.bluetooth;

import android.content.BroadcastReceiver;
import android.content.Context;
import android.content.Intent;
import android.util.Log;

/** Public automation hook: resumes only readiness previously enabled in setup. */
public final class AutomationReceiver extends BroadcastReceiver {
    public static final String ACTION_START_READY = "app.droidmirror.bluetooth.action.START_READY";

    @Override public void onReceive(Context context, Intent intent) {
        if (intent == null || !ACTION_START_READY.equals(intent.getAction())) return;
        CaptureService.ReadyResult result = CaptureService.enableIfConfigured(context);
        Log.i("DroidMirrorReady", result.name());
        if (isOrderedBroadcast()) {
            setResultCode(result == CaptureService.ReadyResult.START_REQUESTED ? -1 : 0);
            setResultData(result.name());
        }
    }
}
