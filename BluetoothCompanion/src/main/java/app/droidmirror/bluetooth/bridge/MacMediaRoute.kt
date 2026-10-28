package app.droidmirror.bluetooth.bridge

import android.annotation.TargetApi
import android.content.Context
import android.media.MediaRoute2Info
import android.media.MediaRoute2ProviderService
import android.media.MediaRouter2
import android.media.RouteDiscoveryPreference
import android.media.RoutingSessionInfo
import android.net.Uri
import android.os.Bundle
import app.droidmirror.bluetooth.R

/** This route describes the Music remote-control session; it does not route phone audio. */
@TargetApi(30)
class MacMediaRoute(context: Context, private val onController: (String?) -> Unit) : AutoCloseable {
    private val router = MediaRouter2.getInstance(context)
    private val packageName = context.packageName
    private var active = false
    private var transferring = false
    private var scan: AutoCloseable? = null
    private val handler = android.os.Handler(android.os.Looper.getMainLooper())
    private val executor = java.util.concurrent.Executor { handler.post(it) }
    private val transfers = object : MediaRouter2.TransferCallback() {
        override fun onTransfer(oldController: MediaRouter2.RoutingController, newController: MediaRouter2.RoutingController) {
            transferring = false
            if (active && newController.selectedRoutes.any { ownRoute(it) }) {
                onController(newController.id)
                scan?.close(); scan = null
            }
        }
        override fun onTransferFailure(requestedRoute: MediaRoute2Info) { transferring = false }
        override fun onStop(controller: MediaRouter2.RoutingController) { if (active) onController(null) }
    }
    private val callback = object : MediaRouter2.RouteCallback() {
        override fun onRoutesAdded(routes: List<MediaRoute2Info>) = select(routes)
        override fun onRoutesChanged(routes: List<MediaRoute2Info>) = select(routes)
    }
    private fun ownRoute(route: MediaRoute2Info) = route.id.endsWith(":" + MacMediaRouteProvider.ROUTE) && route.id.startsWith("$packageName/")
    private fun select(routes: List<MediaRoute2Info>) {
        if (!active) return
        val route = routes.firstOrNull { ownRoute(it) } ?: return
        val current = router.controllers.firstOrNull { c -> c.selectedRoutes.any { it.id == route.id } }
        if (current != null) { onController(current.id); return }
        if (!transferring) { transferring = true; router.transferTo(route) }
    }
    fun setActive(value: Boolean) {
        if (active == value) return
        active = value
        MacMediaRouteProvider.setActive(value)
        if (value) {
            router.registerTransferCallback(executor, transfers)
            router.registerRouteCallback(executor, callback,
                RouteDiscoveryPreference.Builder(listOf(MediaRoute2Info.FEATURE_REMOTE_AUDIO_PLAYBACK), true).build())
            if (android.os.Build.VERSION.SDK_INT >= 35) {
                scan = MacRouteScan(router)
                handler.postDelayed({ scan?.close(); scan = null }, 5000)
            }
            select(router.routes)
        } else {
            router.controllers.filter { c -> c.selectedRoutes.any { it.id.endsWith(":" + MacMediaRouteProvider.ROUTE) && it.id.startsWith("$packageName/") } }
                .forEach { it.release() }
            router.unregisterRouteCallback(callback)
            router.unregisterTransferCallback(transfers)
            scan?.close(); scan = null; transferring = false
            handler.removeCallbacksAndMessages(null)
            onController(null)
        }
    }
    override fun close() = setActive(false)
}

@TargetApi(35)
private class MacRouteScan(private val router: MediaRouter2) : AutoCloseable {
    private var token: MediaRouter2.ScanToken? = router.requestScan(MediaRouter2.ScanRequest.Builder().build())
    override fun close() { token?.let { router.cancelScanRequest(it) }; token = null }
}

@TargetApi(30)
class MacMediaRouteProvider : MediaRoute2ProviderService() {
    companion object {
        const val ROUTE = "droidmirror_mac_music"
        private var active = false
        private var instance: MacMediaRouteProvider? = null
        fun setActive(value: Boolean) { active = value; instance?.publish() }
    }
    override fun onCreate() { super.onCreate(); instance = this; publish() }
    override fun onDestroy() { if (instance === this) instance = null; super.onDestroy() }
    private fun publish() {
        if (!active) {
            allSessionInfo.forEach { notifySessionReleased(it.id) }
            notifyRoutes(emptyList()); return
        }
        notifyRoutes(listOf(MediaRoute2Info.Builder(ROUTE, "Mac laptop")
            .addFeature(MediaRoute2Info.FEATURE_REMOTE_AUDIO_PLAYBACK)
            .setType(MediaRoute2Info.TYPE_REMOTE_COMPUTER)
            .setDescription("Apple Music on Mac")
            .setIconUri(Uri.parse("android.resource://$packageName/${R.drawable.ic_laptop}"))
            .setConnectionState(MediaRoute2Info.CONNECTION_STATE_CONNECTED)
            .setVolumeHandling(MediaRoute2Info.PLAYBACK_VOLUME_FIXED).build()))
    }
    override fun onCreateSession(requestId: Long, packageName: String, routeId: String, sessionHints: Bundle?) {
        // Never advertise this control proxy as an audio sink for another application.
        if (!active || packageName != this.packageName || routeId != ROUTE) {
            notifyRequestFailed(requestId, REASON_REJECTED); return
        }
        notifySessionCreated(requestId, RoutingSessionInfo.Builder("music_$requestId", packageName)
            .setName("Mac laptop").addSelectedRoute(ROUTE)
            .setVolumeHandling(MediaRoute2Info.PLAYBACK_VOLUME_FIXED).build())
    }
    override fun onReleaseSession(requestId: Long, sessionId: String) { notifySessionReleased(sessionId) }
    override fun onSelectRoute(requestId: Long, sessionId: String, routeId: String) { notifyRequestFailed(requestId, REASON_REJECTED) }
    override fun onDeselectRoute(requestId: Long, sessionId: String, routeId: String) { notifyRequestFailed(requestId, REASON_REJECTED) }
    override fun onTransferToRoute(requestId: Long, sessionId: String, routeId: String) { notifyRequestFailed(requestId, REASON_REJECTED) }
    override fun onSetRouteVolume(requestId: Long, routeId: String, volume: Int) { notifyRequestFailed(requestId, REASON_REJECTED) }
    override fun onSetSessionVolume(requestId: Long, sessionId: String, volume: Int) { notifyRequestFailed(requestId, REASON_REJECTED) }
}
