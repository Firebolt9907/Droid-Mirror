package app.droidmirror.bluetooth.bridge

import app.droidmirror.bluetooth.SecureSettingsPermission
import rikka.shizuku.Shizuku
import android.content.Intent
import android.content.Context
import android.content.BroadcastReceiver
import android.content.IntentFilter
import android.bluetooth.BluetoothAdapter
import android.os.Build
import android.net.ConnectivityManager
import android.net.Network
import android.net.NetworkCapabilities
import android.net.NetworkRequest
import android.os.Handler
import android.os.Looper
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicInteger
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale

/** Discovery/notification runtime owned by CaptureService, never a second service. */
class BridgeRuntime(private val context: Context, private val onChanged: Runnable) : AutoCloseable {
    companion object { @Volatile var live: BridgeRuntime? = null }

    private val shizukuReceived = Shizuku.OnBinderReceivedListener { ensureSecureSettings() }
    private val shizukuPermission = Shizuku.OnRequestPermissionResultListener { _, _ -> ensureSecureSettings() }
    private fun ensureSecureSettings() {
        if (!destroyed && !SecureSettingsPermission.granted(context) && SecureSettingsPermission.shizukuAuthorized()) {
            SecureSettingsPermission.ensure(context) {
                if (!destroyed && SecureSettingsPermission.granted(context)) findEndpoint()
            }
        }
    }
    @Volatile private var destroyed = false
    private val bluetoothChanged = object : BroadcastReceiver() {
        override fun onReceive(context: Context, intent: Intent) {
            when (intent.getIntExtra(BluetoothAdapter.EXTRA_STATE, -1)) {
                BluetoothAdapter.STATE_ON -> runCatching { ble.start { update(it, details) } }
                    .onFailure { update("Bluetooth unavailable", "Check Nearby Devices permission and try again.") }
                BluetoothAdapter.STATE_TURNING_OFF -> handler.post { leftBehind?.disarm() }
                BluetoothAdapter.STATE_OFF -> { ble.stop(); update("Bluetooth is off", details) }
            }
        }
    }
    private var leftBehind: LeftBehindMonitor? = null
    fun suspendPresenceProbes() { handler.post { if (!destroyed) leftBehind?.suspendRadioProbes() } }
    fun refreshLeftBehind() { handler.post { if (!destroyed) leftBehind?.refresh() } }
    private lateinit var finder: AdbEndpointFinder
    private var clipboard: app.droidmirror.bluetooth.ClipboardSyncClient? = null
    private var media: PhoneMediaSync? = null
    private val sharedLinks = mutableMapOf<String, java.util.function.Consumer<Boolean>>()
    fun shareLink(url: String, reply: java.util.function.Consumer<Boolean>): String? {
        if (destroyed || sharedLinks.isNotEmpty() || !app.droidmirror.bluetooth.TaskUrlResolver.webUrl(url)) {
            reply.accept(false); return null
        }
        val id = java.util.UUID.randomUUID().toString()
        sharedLinks[id] = reply
        if (!ble.shareLink(url, id)) { sharedLinks.remove(id); reply.accept(false); return null }
        return id
    }
    fun cancelSharedLink(id: String) { sharedLinks.remove(id) }
    private var taskGeneration = 0L
    private var taskUrls: app.droidmirror.bluetooth.TaskUrlClient? = null
    private var hotspot: app.droidmirror.bluetooth.HotspotClient? = null
    private lateinit var ble: BlePeripheral
    private val handler = Handler(Looper.getMainLooper())
    private val refreshRunning = AtomicBoolean(false)
    private val fastRefreshesRemaining = AtomicInteger(0)
    private val refreshRunnable = Runnable { refreshEndpoint() }
    private lateinit var connectivity: ConnectivityManager
    private val networkCallback = object : ConnectivityManager.NetworkCallback() {
        override fun onAvailable(network: Network) = networkChanged()
        override fun onLost(network: Network) = networkChanged()
        override fun onCapabilitiesChanged(network: Network, caps: NetworkCapabilities) =
            networkChanged()
    }
    private val wifiCallback = object : ConnectivityManager.NetworkCallback() {
        override fun onAvailable(network: Network) = networkChanged()
        override fun onLost(network: Network) = networkChanged()
        override fun onCapabilitiesChanged(network: Network, caps: NetworkCapabilities) =
            networkChanged()
    }

    var status: String = "Starting background bridge…"
        private set
    var details: String = ""
        private set

    fun start() {
        leftBehind = LeftBehindMonitor(context)
        hotspot = app.droidmirror.bluetooth.HotspotClient(context)
        finder = AdbEndpointFinder(context)
        ble = BlePeripheral(
            context = context,
            endpoint = { finder.endpoint },
            onPresence = { peer, present -> handler.post { if (!destroyed) leftBehind?.presence(peer, present) } },
            onPresenceReset = { handler.post { if (!destroyed) leftBehind?.disarm() } },
            onWatchEvent = { event, valid, send -> WearPhoneBridge.receiveMac(context, event, valid, send) },
            onCommand = { command ->
                if (command == "CONNECTED") update("Mac connected", details)
                else if (finder.endpoint != null) update("Ready for Mac", details)
            },
            onClipboardSubscription = { enabled, generation, files -> handler.post {
                clipboard?.close(); clipboard = null
                if (enabled && !destroyed) clipboard = app.droidmirror.bluetooth.ClipboardSyncClient(context, files) { ble.sendClipboardEvent(it, generation) }
            } },
            onClipboardText = { text -> handler.post { if (!destroyed) clipboard?.setText(text) } },
            onClipboardFile = { event -> handler.post { if (!destroyed) clipboard?.fileEvent(event) } },
            onMediaSubscription = { enabled, generation -> handler.post {
                media?.close(); media = null
                if (enabled && !destroyed) media = PhoneMediaSync(context) { ble.sendMediaEvent(it, generation) }
            } },
            onMediaEvent = { event, authorized -> handler.post {
                if (!destroyed && authorized()) media?.receive(event)
            } },
            onTaskSubscription = { enabled, generation -> handler.post {
                taskGeneration = generation
                taskUrls?.setSubscribed(enabled && !destroyed)
            } },
            onShareLinkResult = { id, success -> handler.post { sharedLinks.remove(id)?.accept(success) } },
            onOpenLink = { url, authorized, reply -> handler.post {
                val client = taskUrls
                if (!destroyed && authorized() && client != null) client.openBrowser(url, { !destroyed && authorized() }, reply)
                else reply(false)
            } },
            onHotspotToggle = { enabled, authorized, reply -> handler.post {
                if (!destroyed && authorized()) hotspot?.setEnabled(enabled) { reply(it) }
            } }
        )
        taskUrls = app.droidmirror.bluetooth.TaskUrlClient(context) { ble.sendTaskEvent(it, taskGeneration) }
        runCatching { ble.start { update(it, details) } }
            .onFailure { update("Bluetooth unavailable", "Check Nearby Devices permission and try again.") }
        val filter = IntentFilter(BluetoothAdapter.ACTION_STATE_CHANGED)
        if (Build.VERSION.SDK_INT >= 33) context.registerReceiver(bluetoothChanged, filter, Context.RECEIVER_EXPORTED)
        else context.registerReceiver(bluetoothChanged, filter)
        connectivity = context.getSystemService(ConnectivityManager::class.java)
        connectivity.registerDefaultNetworkCallback(networkCallback)
        connectivity.registerNetworkCallback(
            NetworkRequest.Builder()
                .addTransportType(NetworkCapabilities.TRANSPORT_WIFI)
                .build(),
            wifiCallback
        )
        live = this
        WearPhoneBridge.refresh(context)
        Shizuku.addBinderReceivedListenerSticky(shizukuReceived)
        Shizuku.addRequestPermissionResultListener(shizukuPermission)
        findEndpoint()
    }

    fun sendEvent(value: org.json.JSONObject) { ble.sendEvent(value) }
    fun canForwardHaptics(): Boolean = ble.canForwardHaptics()
    fun resetTrust() { ble.revokeTrust() }

    @JvmOverloads fun findEndpoint(enableWirelessDebugging: Boolean = false) {
        if (destroyed) return
        // Iroh video and notifications never enable Android's debugging listener.
        // Retain the old ADB bridge only behind an explicit optional setup action.
        if (!enableWirelessDebugging) { refreshEndpoint(); return }
        if (!refreshRunning.compareAndSet(false, true)) return
        finder.enableAndFind(
            onStatus = { update(it, details) },
            onDone = { result ->
                refreshRunning.set(false)
                if (destroyed) return@enableAndFind
                result.onSuccess {
                    update(
                        "Ready for Mac",
                        "Port: ${it.port}\nTailscale: ${it.tailscaleIp ?: "not detected"}"
                    )
                    ble.publish()
                }.onFailure {
                    update("Could not start ADB", it.message ?: it.javaClass.simpleName)
                }
                scheduleRefresh(nextRefreshDelay())
            }
        )
    }

    private fun refreshEndpoint() {
        if (destroyed) return
        if (!refreshRunning.compareAndSet(false, true)) {
            scheduleRefresh(5_000)
            return
        }
        val previousPort = finder.endpoint?.port
        finder.refreshExisting { result ->
            if (destroyed) return@refreshExisting
            refreshRunning.set(false)
            result.onSuccess { current ->
                val checkedDetails = current?.let {
                    "Port: ${it.port}\nTailscale: ${it.tailscaleIp ?: "not detected"}\nLast checked: ${checkTime()}"
                }
                when {
                    current == null && previousPort != null -> {
                        update("Waiting for a new ADB port", "Wireless Debugging listener is offline")
                        ble.publish()
                    }
                    current == null -> update("Bluetooth ready", "Iroh video uses direct LAN only. Wireless ADB is the optional fallback.")
                    current.port != previousPort -> {
                        update(
                            "Ready for Mac",
                            checkedDetails.orEmpty()
                        )
                        ble.publish()
                        // Keep the Bluetooth connection: this app may also have
                        // an active BLE input session with the same Mac.
                    }
                    else -> {
                        updateDetailsOnly(checkedDetails.orEmpty())
                        // Periodic republish makes a dropped BLE notification harmless.
                        ble.publish()
                    }
                }
            }.onFailure {
                update("Waiting for ADB", it.message ?: it.javaClass.simpleName)
            }
            scheduleRefresh(nextRefreshDelay())
        }
    }

    private fun networkChanged() {
        // adbd and its mDNS record can appear shortly after the Wi-Fi callback.
        // Check immediately, then keep a brief two-second retry window.
        fastRefreshesRemaining.set(5)
        scheduleRefresh(250)
    }

    private fun nextRefreshDelay(): Long {
        while (true) {
            val remaining = fastRefreshesRemaining.get()
            if (remaining <= 0) return 15_000
            if (fastRefreshesRemaining.compareAndSet(remaining, remaining - 1)) return 2_000
        }
    }

    private fun scheduleRefresh(delayMillis: Long) {
        if (destroyed) return
        handler.removeCallbacks(refreshRunnable)
        handler.postDelayed(refreshRunnable, delayMillis)
    }

    private fun checkTime(): String =
        SimpleDateFormat("HH:mm:ss", Locale.getDefault()).format(Date())

    private fun updateDetailsOnly(newDetails: String) {
        if (Looper.myLooper() != Looper.getMainLooper()) {
            handler.post { updateDetailsOnly(newDetails) }; return
        }
        if (destroyed) return
        details = newDetails
    }

    private fun update(newStatus: String, newDetails: String) {
        if (Looper.myLooper() != Looper.getMainLooper()) {
            handler.post { update(newStatus, newDetails) }; return
        }
        if (destroyed) return
        status = newStatus
        details = newDetails
        onChanged.run()
    }

    override fun close() {
        destroyed = true
        leftBehind?.close(); leftBehind = null
        media?.close(); media = null
        hotspot?.close(); hotspot = null
        clipboard?.close(); clipboard = null
        sharedLinks.values.toList().forEach { it.accept(false) }; sharedLinks.clear()
        taskUrls?.close(); taskUrls = null
        Shizuku.removeBinderReceivedListener(shizukuReceived)
        Shizuku.removeRequestPermissionResultListener(shizukuPermission)
        runCatching { context.unregisterReceiver(bluetoothChanged) }
        live = null
        WearPhoneBridge.disconnected(context)
        handler.removeCallbacksAndMessages(null)
        runCatching { connectivity.unregisterNetworkCallback(networkCallback) }
        runCatching { connectivity.unregisterNetworkCallback(wifiCallback) }
        runCatching { ble.stop() }
    }
}
