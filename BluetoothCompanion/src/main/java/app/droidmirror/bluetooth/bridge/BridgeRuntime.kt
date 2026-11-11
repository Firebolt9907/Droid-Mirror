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
    fun refreshTrustedPlaces() { handler.post { if (!destroyed) leftBehind?.trustedPlacesChanged() } }
    fun refreshLeftBehind() { handler.post { if (!destroyed) leftBehind?.refresh() } }
    private lateinit var finder: AdbEndpointFinder
    private var clipboard: app.droidmirror.bluetooth.ClipboardSyncClient? = null
    private val clipboardActivity = ClipboardSyncActivity(context)
    fun cancelClipboardSync(id: String, token: String) { handler.post {
        if (destroyed || !clipboardActivity.matches(id, token)) return@post
        val preparingOnly = clipboardActivity.isPreparing(id)
        clipboard?.cancelFile(id)
        // Sequenced control survives closing both bulk transports immediately.
        ble.sendClipboardEvent(org.json.JSONObject().put("type", "clipboardFileStop").put("id", id), clipboardGeneration)
        val cancel = org.json.JSONObject().put("type", "clipboardFileCancel").put("id", id)
        if (!preparingOnly) clipboardRace?.send(cancel)
        ble.sendClipboardEvent(cancel, clipboardGeneration) // legacy non-bulk peer
        closeClipboardBulk()
    } }
    private fun receiveClipboardFile(event: org.json.JSONObject, lane: Int) {
        clipboardActivity.observe(event, false)
        if (clipboardRaceEnabled) race().receive(event, lane) else clipboard?.fileEvent(event)
    }
    @Volatile private var bulkTest: BleBulkTest? = null
    @Volatile private var bulkTestGeneration = 0L
    private var clipboardIrohEpoch = 0L
    private var clipboardIroh: ClipboardIrohChannel? = null
    private var clipboardRace: ClipboardTransferRace? = null
    private var clipboardRaceEnabled = false
    private var clipboardIrohAttempted = false
    private var clipboardIrohReplayID: String? = null
    private fun race(): ClipboardTransferRace {
        clipboardRace?.let { return it }
        return ClipboardTransferRace({ lane, event ->
            if (lane == 0) {
                val channel = openClipboardBulk(clipboardGeneration)
                val ok = channel?.send(event) == true
                if (!ok) { channel?.close(); clipboardBulk = null }; ok
            } else if (clipboardIrohReplayID == event.optString("id") &&
                event.optString("type") in setOf("clipboardFileBegin", "clipboardFileChunk")) {
                // History retains these chunks until source validation finishes.
                // Queue the complete prefix before allowing newer chunks through.
                true
            } else openClipboardIroh(clipboardGeneration)?.send(event) == true
        }, { clipboard?.fileEvent(it) }, { lane ->
            android.util.Log.i("DroidMirrorClipboard", "Clipboard race winner=${if (lane == 1) "iroh" else "l2cap"}")
            if (lane == 1) { clipboardBulk?.close(); clipboardBulk = null }
            else { clipboardIroh?.close(); clipboardIroh = null }
        }).also { it.started = { clipboardIrohAttempted = clipboardIroh != null; openClipboardIroh(clipboardGeneration) }; clipboardRace = it }
    }
    private fun openClipboardIroh(generation: Long): ClipboardIrohChannel? {
        if (!clipboardRaceEnabled || !clipboardReady || !ble.clipboardAuthorized(generation)) return null
        clipboardIroh?.let { return it }
        if (clipboardIrohAttempted) return null
        clipboardIrohAttempted = true
        val epoch = ++clipboardIrohEpoch
        return runCatching {
            ClipboardIrohChannel(context, requireNotNull(BleTrust.key(context)),
                { !destroyed && ble.clipboardAuthorized(generation) },
                { if (clipboardGeneration == generation && clipboardIrohEpoch == epoch) receiveClipboardFile(it, 1) },
                { if (clipboardGeneration == generation && clipboardIrohEpoch == epoch) {
                    clipboardIroh?.close(); clipboardIroh = null
                    if (clipboardBulk == null) { clipboardActivity.clear(); clipboard?.bulkFailed() }
                } }).also { channel ->
                    clipboardIroh = channel
                    fun publish(attempt: Int) {
                        if (clipboardIroh !== channel || !ble.clipboardAuthorized(generation)) return
                        val offer = channel.offer
                        if (offer.getJSONArray("addresses").length() > 0 || attempt >= 15) ble.sendClipboardEvent(offer, generation)
                        else handler.postDelayed({ publish(attempt + 1) }, 100)
                    }
                    publish(0)
                }
        }.getOrElse { clipboardIroh = null; null }
    }
    private var clipboardBulk: ClipboardBulkChannel? = null
    private var clipboardBulkEpoch = 0L
    private var clipboardBulkEnabled = false
    private var clipboardGeneration = 0L
    private var clipboardReady = false
    private fun closeClipboardBulk() { clipboardActivity.clear(); ++clipboardBulkEpoch; clipboardBulk?.close(); clipboardBulk = null
        ++clipboardIrohEpoch; clipboardIroh?.close(); clipboardIroh = null; clipboardRace = null; clipboardIrohAttempted = false; clipboardIrohReplayID = null }
    private fun openClipboardBulk(generation: Long, resendOffer: Boolean = false): ClipboardBulkChannel? {
        if (!clipboardBulkEnabled || !clipboardReady || !ble.clipboardAuthorized(generation)) return null
        clipboardBulk?.let {
            if (resendOffer && !it.connected) ble.sendClipboardEvent(it.offer, generation)
            return it
        }
        val epoch = ++clipboardBulkEpoch
        ble.preferClipboardBulkPhy(generation)
        return runCatching {
            val channel = ClipboardBulkChannel(context, requireNotNull(BleTrust.key(context)),
                { !destroyed && ble.clipboardAuthorized(generation) },
                { if (clipboardGeneration == generation) receiveClipboardFile(it, 0) },
                { if (clipboardGeneration == generation && clipboardBulkEpoch == epoch) { clipboardBulk = null; if (clipboardIroh == null) { clipboardActivity.clear(); clipboard?.bulkFailed() } } })
            clipboardBulk = channel
            ble.sendClipboardEvent(channel.offer, generation)
            channel
        }.getOrElse { clipboard?.bulkFailed(); null }
    }
    private fun clipboardEvent(event: org.json.JSONObject, generation: Long) {
        if (generation != clipboardGeneration || destroyed) return
        if (event.optString("type") in setOf("clipboardFilePrepare", "clipboardFilePrepareEnd")) {
            clipboardActivity.observe(event, true); return
        }
        if (event.optString("type") == "clipboardStatus") {
            clipboardReady = event.optString("status") == "ready"
            if (!clipboardReady) closeClipboardBulk()
        }
        if (event.optString("type") in ClipboardBulkCodec.FILES) clipboardActivity.observe(event, true)
        if (clipboardBulkEnabled && event.optString("type") in ClipboardBulkCodec.FILES) {
            if (clipboardRaceEnabled) {
                if (event.optString("type") == "clipboardFileBegin") clipboardIrohAttempted = clipboardIroh != null
                if (!race().send(event)) { closeClipboardBulk(); clipboard?.bulkFailed() }
                return
            }
            if (event.optString("type") == "clipboardFileCancel" && clipboardBulk == null) return
            if (openClipboardBulk(generation)?.send(event) != true) {
                closeClipboardBulk(); clipboard?.bulkFailed()
            }
        } else ble.sendClipboardEvent(event, generation)
    }
    private var focusSync: PhoneFocusSync? = null
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
    @Volatile private var taskUrls: app.droidmirror.bluetooth.TaskUrlClient? = null
    private val appLibrary = PhoneAppLibrary(context, { taskUrls?.notificationReady() == true }) { taskUrls?.openLauncher(it) == true }
    fun notificationOpenerReady(): Boolean = !destroyed && taskUrls?.notificationReady() == true
    fun openNotification(intent: android.app.PendingIntent): Boolean =
        !destroyed && taskUrls?.openNotification(intent) == true
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
        focusSync = PhoneFocusSync(context)
        hotspot = app.droidmirror.bluetooth.HotspotClient(context)
        finder = AdbEndpointFinder(context)
        ble = BlePeripheral(
            context = context,
            endpoint = { finder.endpoint },
            onPresence = { _, present -> handler.post { if (!destroyed) leftBehind?.presence(present) } },
            onPresenceReset = { handler.post { if (!destroyed) leftBehind?.disarm() } },
            onWatchEvent = { event, valid, send -> WearPhoneBridge.receiveMac(context, event, valid, send) },
            onCommand = { command ->
                if (command == "CONNECTED") update("Mac connected", details)
                else if (finder.endpoint != null) update("Ready for Mac", details)
            },
            onClipboardSubscription = { enabled, generation, files, bulk, racing -> handler.post {
                closeClipboardBulk(); clipboard?.close(); clipboard = null
                clipboardGeneration = generation; clipboardRaceEnabled = enabled && files && bulk && racing; clipboardBulkEnabled = enabled && files && bulk; clipboardReady = false
                if (enabled && !destroyed) clipboard = app.droidmirror.bluetooth.ClipboardSyncClient(context, files, bulk) { clipboardEvent(it, generation) }
            } },
            onBulkTest = { config, generation -> handler.post {
                bulkTest?.close(); bulkTest = null; bulkTestGeneration = generation
                if (config != null && !destroyed && ble.bulkTestAuthorized(generation)) {
                    ble.preferBulkTestPhy(generation)
                    runCatching {
                        val test = BleBulkTest(context, config, requireNotNull(ble.bulkTestPeer(generation)), { !destroyed && ble.bulkTestAuthorized(generation) },
                            { event -> ble.sendBulkTestEvent(event, generation) })
                        bulkTest = test; test.start()
                    }.onFailure { bulkTest?.close(); bulkTest = null; ble.sendBulkTestEvent(org.json.JSONObject().put("type", "bulkTestError")
                        .put("id", config.optString("id")).put("reason", "setup failed"), generation) }
                }
            } },
            onBulkTestData = { value, generation -> if (bulkTestGeneration == generation) bulkTest?.fragment(value) },
            onClipboardIrohOpen = { generation, retry -> handler.post {
                if (generation == clipboardGeneration && clipboardReady && ble.clipboardAuthorized(generation)) {
                    if (retry) {
                        ++clipboardIrohEpoch; clipboardIroh?.close(); clipboardIroh = null; clipboardIrohAttempted = false
                        clipboardRace?.restartLane(1)
                        clipboardIrohReplayID = clipboardRace?.outgoingID
                    }
                    if (openClipboardIroh(generation) != null && retry) {
                        val epoch = clipboardIrohEpoch
                        val id = clipboardRace?.outgoingID
                        if (id != null) clipboard?.canReplayFile(id) { allowed ->
                            if (generation == clipboardGeneration && epoch == clipboardIrohEpoch && clipboardRace?.outgoingID == id) {
                                clipboardIrohReplayID = null
                                if (allowed) clipboardRace?.catchUp(1)
                                else { ++clipboardIrohEpoch; clipboardIroh?.close(); clipboardIroh = null }
                            }
                        }
                    }
                }
            } },
            onClipboardBulkOpen = { generation -> handler.post { openClipboardBulk(generation, resendOffer = true) } },
            onClipboardText = { text -> handler.post { if (!destroyed) clipboard?.setText(text) } },
            onClipboardPreparation = { event, generation -> handler.post {
                if (!destroyed && clipboardGeneration == generation && clipboardReady && ble.clipboardAuthorized(generation)) {
                    clipboardActivity.observe(event, false)
                    if (event.optString("type") == "clipboardFilePrepare") ble.sendClipboardEvent(org.json.JSONObject()
                        .put("type", "clipboardFilePrepareReady").put("id", event.getString("id")).put("request", event.optString("request")), generation)
                }
            } },
            onClipboardFile = { event -> handler.post { if (!destroyed) receiveClipboardFile(event, 0) } },
            onMediaSubscription = { enabled, generation -> handler.post {
                media?.close(); media = null
                if (enabled && !destroyed) media = PhoneMediaSync(context) { ble.sendMediaEvent(it, generation) }
            } },
            onMediaEvent = { event, authorized -> handler.post {
                if (!destroyed && authorized()) media?.receive(event)
            } },
            onTaskSubscription = { enabled, generation, changeOnly -> handler.post {
                taskGeneration = generation
                taskUrls?.setSubscribed(enabled && !destroyed, changeOnly)
            } },
            onCatalogSubscription = { peer, authorized, reply -> appLibrary.subscribeCatalog(peer, authorized, reply) },
            onAppLibrary = { command, authorized, reply -> appLibrary.receive(command, authorized, reply) },
            onShareLinkResult = { id, success -> handler.post { sharedLinks.remove(id)?.accept(success) } },
            onOpenLink = { url, authorized, reply -> handler.post {
                val client = taskUrls
                if (!destroyed && authorized() && client != null) client.openBrowser(url, { !destroyed && authorized() }, reply)
                else reply(false)
            } },
            onFocus = { command, authorized, reply -> handler.post {
                if (!destroyed && authorized()) focusSync?.receive(command)?.let { reply(it) }
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

    fun notificationStreamReady(): Boolean = !destroyed && ble.canForwardHaptics()
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
                        // Publish changed endpoints; the BLE publisher suppresses unchanged values per session.
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
        focusSync?.close(); focusSync = null
        hotspot?.close(); hotspot = null
        bulkTest?.close(); bulkTest = null
        closeClipboardBulk(); clipboard?.close(); clipboard = null
        sharedLinks.values.toList().forEach { it.accept(false) }; sharedLinks.clear()
        taskUrls?.close(); taskUrls = null
        appLibrary.close()
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
