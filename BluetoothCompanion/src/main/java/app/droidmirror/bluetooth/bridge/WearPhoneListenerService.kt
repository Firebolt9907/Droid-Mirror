package app.droidmirror.bluetooth.bridge

import com.google.android.gms.wearable.MessageEvent
import com.google.android.gms.wearable.WearableListenerService

class WearPhoneListenerService : WearableListenerService() {
    override fun onMessageReceived(event: MessageEvent) =
        WearPhoneBridge.message(applicationContext, event.sourceNodeId, event.path, event.data)
}
