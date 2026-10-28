package app.droidmirror.wear;

import com.google.android.gms.wearable.MessageEvent;
import com.google.android.gms.wearable.Node;
import com.google.android.gms.wearable.WearableListenerService;

public final class WatchListenerService extends WearableListenerService {
    @Override public void onMessageReceived(MessageEvent event) {
        WatchState.receive(getApplicationContext(), event.getSourceNodeId(), event.getPath(), event.getData());
    }
    @Override public void onPeerDisconnected(Node peer) {
        WatchState.MAIN.post(() -> { if (peer.getId().equals(WatchState.node)) WatchState.offline(getApplicationContext()); });
    }
}
