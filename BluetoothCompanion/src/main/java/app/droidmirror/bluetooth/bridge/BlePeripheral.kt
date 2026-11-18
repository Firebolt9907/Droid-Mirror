package app.droidmirror.bluetooth.bridge

import app.droidmirror.bluetooth.BleLinkMtu
import android.annotation.SuppressLint
import android.bluetooth.BluetoothAdapter
import android.bluetooth.BluetoothGatt
import android.bluetooth.BluetoothGattCharacteristic
import android.bluetooth.BluetoothGattDescriptor
import android.bluetooth.BluetoothGattServer
import android.bluetooth.BluetoothGattServerCallback
import android.bluetooth.BluetoothManager
import android.bluetooth.BluetoothProfile
import android.bluetooth.BluetoothStatusCodes
import android.bluetooth.le.AdvertiseCallback
import android.bluetooth.le.AdvertiseData
import android.bluetooth.le.AdvertiseSettings
import android.content.Context
import android.os.Build
import android.os.ParcelUuid
import org.json.JSONObject
import java.util.UUID
import java.util.concurrent.ConcurrentHashMap

class BlePeripheral(
    private val context: Context,
    private val endpoint: () -> AdbEndpoint?,
    private val onWatchEvent: (JSONObject, () -> Boolean, (JSONObject) -> Boolean) -> Unit = { _, _, _ -> },
    /** (computer address, present): an authenticated background session started or ended. */
    private val onPresence: (String, Boolean) -> Unit = { _, _ -> },
    private val onPresenceReset: () -> Unit = {},
    private val onCommand: (String) -> Unit = {},
    private val onClipboardSubscription: (Boolean, Long, Boolean, Boolean, Boolean) -> Unit = { _, _, _, _, _ -> },
    private val onBulkTest: (JSONObject?, Long) -> Unit = { _, _ -> },
    private val onBulkTestData: (ByteArray, Long) -> Unit = { _, _ -> },
    private val onClipboardBulkOpen: (Long) -> Unit = {},
    private val onClipboardIrohOpen: (Long, Boolean) -> Unit = { _, _ -> },
    private val onClipboardText: (String) -> Unit = {},
    private val onClipboardFile: (JSONObject) -> Unit = {},
    private val onClipboardPreparation: (JSONObject, Long) -> Unit = { _, _ -> },
    private val onMediaSubscription: (Boolean, Long) -> Unit = { _, _ -> },
    private val onMediaEvent: (JSONObject, () -> Boolean) -> Unit = { _, _ -> },
    private val onTaskSubscription: (Boolean, Long, Boolean) -> Unit = { _, _, _ -> },
    private val onCatalogSubscription: (String, () -> Boolean, (JSONObject) -> Unit) -> Unit = { _, _, reply -> reply(JSONObject().put("success", false)) },
    private val onAppLibrary: (String, JSONObject, () -> Boolean, (JSONObject) -> Unit) -> Unit = { _, _, _, reply -> reply(JSONObject().put("success", false)) },
    private val onOpenLink: (String, () -> Boolean, (Boolean) -> Unit) -> Unit = { _, _, reply -> reply(false) },
    private val onShareLinkResult: (String, Boolean) -> Unit = { _, _ -> },
    private val onFocus: (JSONObject, () -> Boolean, (JSONObject) -> Unit) -> Unit = { _, _, _ -> },
    private val onHotspotToggle: (Boolean, () -> Boolean, (JSONObject) -> Unit) -> Unit = { _, _, reply -> reply(JSONObject().put("status", "unsupported")) }
) {
    companion object {
        val SERVICE_UUID: UUID = UUID.fromString("7e57b000-9a6b-4c5d-8e7f-102030405060")
        val BULK_TEST_UUID: UUID = UUID.fromString("7e57b002-9a6b-4c5d-8e7f-102030405060")
        val ENDPOINT_UUID: UUID = UUID.fromString("7e57b001-9a6b-4c5d-8e7f-102030405060")
        private val CCC_UUID: UUID = UUID.fromString("00002902-0000-1000-8000-00805f9b34fb")
    }

    private val manager = context.getSystemService(BluetoothManager::class.java)
    private val adapter: BluetoothAdapter? get() = manager.adapter
    private var server: BluetoothGattServer? = null
    private var characteristic: BluetoothGattCharacteristic? = null
    /** Device -> computer of each authenticated background session (the activity gate). */
    private val presencePeers = ConcurrentHashMap<android.bluetooth.BluetoothDevice, String>()
    private val connected = ConcurrentHashMap.newKeySet<android.bluetooth.BluetoothDevice>()
    private val subscribed = ConcurrentHashMap<android.bluetooth.BluetoothDevice, Boolean>()
    private val indicationInFlight = ConcurrentHashMap.newKeySet<android.bluetooth.BluetoothDevice>()
    private val notificationMode = ConcurrentHashMap.newKeySet<android.bluetooth.BluetoothDevice>()
    private val pendingIndication = ConcurrentHashMap<android.bluetooth.BluetoothDevice, java.util.ArrayDeque<ByteArray>>()
    private val activityDeltas = ConcurrentHashMap<android.bluetooth.BluetoothDevice, ActivityDeltas>()
    private val pendingMessages = ConcurrentHashMap<android.bluetooth.BluetoothDevice, BleOutboundQueue>()
    private val sessions = ConcurrentHashMap<android.bluetooth.BluetoothDevice, BleSecureSession>()
    private val fragments = ConcurrentHashMap<android.bluetooth.BluetoothDevice, BleFragments>()
    private var cameraDevice: android.bluetooth.BluetoothDevice? = null
    private var nextMessage = 1
    private var advertiser: android.bluetooth.le.BluetoothLeAdvertiser? = null
    private val advertiseCallbacks = mutableListOf<AdvertiseCallback>()
    private val publishedEndpoints = mutableMapOf<android.bluetooth.BluetoothDevice, String>()
    private var publishedPort: Int? = null
    private var revision = 0L
    private var bulkTestDevice: android.bluetooth.BluetoothDevice? = null
    private var bulkTestGeneration = 0L
    private var bulkTestId: String? = null
    // Background features are shared by every computer with an authenticated
    // session (at most ComputerPeers.MAXIMUM). Clipboard text, media and task
    // updates fan out to all subscribers. A clipboard file transfer is one
    // interactive pipeline, owned by the most recent subscriber still connected.
    private val clipboardSubscribers = LinkedHashMap<android.bluetooth.BluetoothDevice, JSONObject>()
    private var clipboardDevice: android.bluetooth.BluetoothDevice? = null
    private var clipboardGeneration = 0L
    private var clipboardBulkRequested = false
    private val linkSubscribers = LinkedHashMap<android.bluetooth.BluetoothDevice, BleSecureSession>()
    private val taskSubscribers = LinkedHashMap<android.bluetooth.BluetoothDevice, Boolean>()
    private var taskGeneration = 0L
    private val mediaSubscribers = LinkedHashSet<android.bluetooth.BluetoothDevice>()
    private var mediaGeneration = 0L
    private var hotspotEpoch = 0L

    // Faster PHY shortens on-air time without adding idle traffic. The controller may
    // retain 1M when either peer or current radio conditions cannot support 2M.
    @Synchronized fun preferClipboardBulkPhy(generation: Long) {
        if (!clipboardAuthorized(generation) || adapter?.isLe2MPhySupported != true) return
        val device = clipboardDevice ?: return
        runCatching {
            server?.setPreferredPhy(device, android.bluetooth.BluetoothDevice.PHY_LE_2M_MASK,
                android.bluetooth.BluetoothDevice.PHY_LE_2M_MASK, android.bluetooth.BluetoothDevice.PHY_OPTION_NO_PREFERRED)
        }.onFailure { android.util.Log.w("DroidMirrorClipboard", "Could not request 2M PHY", it) }
    }

    private fun live(device: android.bluetooth.BluetoothDevice): BleSecureSession? =
        sessions[device]?.takeIf { it.authenticated && subscribed[device] == true }

    /** Computers that can open a shared link right now. */
    @Synchronized fun linkComputers(): List<String> =
        linkSubscribers.entries.filter { (device, session) -> live(device) === session }.map { it.value.computer }.distinct()

    @Synchronized fun shareLink(url: String, request: String, computer: String?): Boolean {
        val (device, session) = linkSubscribers.entries.lastOrNull { (device, session) ->
            live(device) === session && (computer == null || session.computer == computer)
        }?.toPair() ?: return false
        return runCatching {
            enqueueSecure(device, session, JSONObject().put("type", "shareLink").put("url", url).put("request", request))
        }.getOrElse { revokeSession(device); false }
    }

    @Synchronized fun sendMediaEvent(value: JSONObject, generation: Long) {
        if (generation != mediaGeneration) return
        mediaSubscribers.toList().forEach { device ->
            val session = live(device) ?: return@forEach
            runCatching { enqueueSecure(device, session, value) }.onFailure { revokeSession(device) }
        }
    }

    @Synchronized fun sendTaskEvent(value: JSONObject, generation: Long) {
        if (generation != taskGeneration) return
        taskSubscribers.keys.toList().forEach { device ->
            val session = live(device) ?: return@forEach
            runCatching { enqueueSecure(device, session, value) }.onFailure { revokeSession(device) }
        }
    }

    /** force: a computer joined; restart sync so every subscriber gets a full snapshot. */
    private fun refreshMedia(force: Boolean = false) {
        val active = mediaSubscribers.isNotEmpty()
        if (active != mediaActive || (force && active)) { mediaActive = active; onMediaSubscription(active, ++mediaGeneration) }
    }
    private var mediaActive = false

    private fun refreshTasks() {
        onTaskSubscription(taskSubscribers.isNotEmpty(), ++taskGeneration,
            taskSubscribers.isNotEmpty() && taskSubscribers.values.all { it })
    }

    /** Re-elects the clipboard file owner: the most recent subscriber with a live session. */
    private fun refreshClipboard(force: Boolean = false) {
        val owner = clipboardSubscribers.keys.lastOrNull { live(it) != null }
        val flags = owner?.let { clipboardSubscribers[it] }
        if (!force && owner == clipboardDevice) return
        clipboardDevice = owner
        clipboardBulkRequested = flags != null && flags.optBoolean("files") && flags.optInt("bulk") == 1 && Build.VERSION.SDK_INT >= 29
        onClipboardSubscription(owner != null, ++clipboardGeneration, flags?.optBoolean("files") == true,
            clipboardBulkRequested, flags?.optInt("race") == 1)
    }

    /** The computer whose key protects the current clipboard file channels. */
    @Synchronized fun clipboardComputer(generation: Long): String? =
        if (clipboardAuthorized(generation)) clipboardDevice?.let { sessions[it]?.computer } else null
    @Synchronized fun bulkTestComputer(generation: Long): String? =
        if (bulkTestAuthorized(generation)) bulkTestDevice?.let { sessions[it]?.computer } else null
    /** Computers with an authenticated background session right now. */
    @Synchronized fun activeComputers(): Set<String> = presencePeers.values.toSet()

    @Synchronized fun bulkTestAuthorized(generation: Long): Boolean = generation == bulkTestGeneration &&
        bulkTestDevice?.let { sessions[it]?.authenticated == true } == true
    @Synchronized fun bulkTestPeer(generation: Long): android.bluetooth.BluetoothDevice? = if (bulkTestAuthorized(generation)) bulkTestDevice else null
    @Synchronized fun sendBulkTestEvent(value: JSONObject, generation: Long) {
        if (!bulkTestAuthorized(generation)) return
        val device = bulkTestDevice ?: return
        val session = sessions[device] ?: return
        runCatching { enqueueSecure(device, session, value) }.onFailure { revokeSession(device) }
    }
    @Synchronized fun preferBulkTestPhy(generation: Long) {
        if (!bulkTestAuthorized(generation) || adapter?.isLe2MPhySupported != true) return
        val device = bulkTestDevice ?: return
        runCatching { server?.setPreferredPhy(device, android.bluetooth.BluetoothDevice.PHY_LE_2M_MASK,
            android.bluetooth.BluetoothDevice.PHY_LE_2M_MASK, android.bluetooth.BluetoothDevice.PHY_OPTION_NO_PREFERRED) }
    }

    @Synchronized fun clipboardAuthorized(generation: Long): Boolean {
        val device = clipboardDevice ?: return false
        return generation == clipboardGeneration && sessions[device]?.authenticated == true
    }

    @Synchronized fun sendClipboardEvent(value: JSONObject, generation: Long) {
        if (generation != clipboardGeneration) return
        // Text and availability reach every subscribed computer; file transfer
        // control belongs to the owner's single pipeline.
        val recipients = if (value.optString("type") in setOf("clipboard", "clipboardStatus")) clipboardSubscribers.keys.toList()
            else listOfNotNull(clipboardDevice)
        recipients.forEach { device ->
            val session = live(device) ?: return@forEach
            runCatching { enqueueSecure(device, session, value) }.onFailure { revokeSession(device) }
        }
    }

    @SuppressLint("MissingPermission")
    fun start(onStatus: (String) -> Unit) {
        stop()
        // One connectable advertisement per trusted computer, each carrying only
        // that computer's discovery UUID (a legacy payload fits one 128-bit UUID).
        val discoveries = BleTrust.keys(context).mapNotNull { (_, key) ->
            runCatching { app.droidmirror.bluetooth.PairingKeys.discovery(key) }.getOrNull()
        }.ifEmpty { return onStatus("Select and pair a computer before enabling BLE") }
        val bluetooth = adapter ?: return onStatus("Bluetooth is unavailable")
        val bleAdvertiser = bluetooth.bluetoothLeAdvertiser
            ?: return onStatus("BLE advertising is unavailable")
        advertiser = bleAdvertiser
        val gatt = app.droidmirror.bluetooth.BleGattServerFactory.open(context, manager, callback)
            ?: return onStatus("Could not open BLE GATT server")
        server = gatt

        characteristic = BluetoothGattCharacteristic(
            ENDPOINT_UUID,
            BluetoothGattCharacteristic.PROPERTY_WRITE or
                // The completion callback for an unconfirmed notification can
                // precede radio delivery and flood the shared mirror GATT link.
                BluetoothGattCharacteristic.PROPERTY_INDICATE,
            BluetoothGattCharacteristic.PERMISSION_READ or
                BluetoothGattCharacteristic.PERMISSION_WRITE
        ).apply {
            addDescriptor(
                BluetoothGattDescriptor(
                    CCC_UUID,
                    BluetoothGattDescriptor.PERMISSION_READ or
                        BluetoothGattDescriptor.PERMISSION_WRITE
                )
            )
        }
        val service = android.bluetooth.BluetoothGattService(
            SERVICE_UUID,
            android.bluetooth.BluetoothGattService.SERVICE_TYPE_PRIMARY
        ).apply {
            addCharacteristic(characteristic)
            addCharacteristic(BluetoothGattCharacteristic(BULK_TEST_UUID,
                BluetoothGattCharacteristic.PROPERTY_WRITE_NO_RESPONSE, BluetoothGattCharacteristic.PERMISSION_WRITE))
        }
        gatt.addService(service)

        advertiseStatus = onStatus
        advertise(bleAdvertiser, discoveries, onStatus)
    }

    private var advertiseStatus: ((String) -> Unit)? = null

    @SuppressLint("MissingPermission")
    private fun advertise(bleAdvertiser: android.bluetooth.le.BluetoothLeAdvertiser, discoveries: List<java.util.UUID>, onStatus: (String) -> Unit) {
        for (discovery in discoveries) {
            val callback = object : AdvertiseCallback() {
                override fun onStartSuccess(settingsInEffect: AdvertiseSettings?) =
                    onStatus("BLE ready — waiting for your computer")

                override fun onStartFailure(errorCode: Int) =
                    onStatus("BLE advertising failed: $errorCode")
            }
            advertiseCallbacks.add(callback)
            bleAdvertiser.startAdvertising(
                AdvertiseSettings.Builder()
                    .setAdvertiseMode(AdvertiseSettings.ADVERTISE_MODE_LOW_POWER)
                    .setConnectable(true)
                    .build(),
                AdvertiseData.Builder()
                    .setIncludeDeviceName(false)
                    .addServiceUuid(ParcelUuid(discovery))
                    .build(),
                callback
            )
        }
    }

    /**
     * Re-advertises after a computer was added or removed. Existing GATT
     * sessions (and any active mirror) are left untouched.
     */
    @SuppressLint("MissingPermission")
    @Synchronized fun refreshAdvertising() {
        val bleAdvertiser = advertiser ?: return
        val onStatus = advertiseStatus ?: return
        advertiseCallbacks.forEach { bleAdvertiser.stopAdvertising(it) }
        advertiseCallbacks.clear()
        val discoveries = BleTrust.keys(context).mapNotNull { (_, key) ->
            runCatching { app.droidmirror.bluetooth.PairingKeys.discovery(key) }.getOrNull()
        }
        advertise(bleAdvertiser, discoveries, onStatus)
    }

    @SuppressLint("MissingPermission")
    @Synchronized fun stop() {
        presencePeers.clear()
        onPresenceReset()
        ++hotspotEpoch
        advertiseCallbacks.forEach { advertiser?.stopAdvertising(it) }
        advertiseCallbacks.clear()
        advertiser = null
        mediaSubscribers.clear(); mediaActive = false
        onMediaSubscription(false, ++mediaGeneration)
        bulkTestDevice = null; onBulkTest(null, ++bulkTestGeneration)
        clipboardSubscribers.clear(); clipboardDevice = null
        onClipboardSubscription(false, ++clipboardGeneration, false, false, false)
        taskSubscribers.clear(); linkSubscribers.clear()
        onTaskSubscription(false, ++taskGeneration, false)
        server?.close()
        server = null
        connected.clear()
        subscribed.clear()
        indicationInFlight.clear()
        pendingMessages.clear(); activityDeltas.clear()
        notificationMode.clear()
        pendingIndication.clear()
        publishedEndpoints.clear()
        sessions.clear(); fragments.clear()
    }

    @SuppressLint("MissingPermission")
    @Synchronized
    fun publish(
        target: android.bluetooth.BluetoothDevice? = null,
        requestId: Long? = null
    ) {
        val value = payload(requestId)
        characteristic?.let { item ->
            val recipients: List<Pair<android.bluetooth.BluetoothDevice, Boolean>> =
                if (target == null) subscribed.entries.map { it.key to it.value } else {
                    subscribed[target]?.let { listOf(target to it) } ?: emptyList()
                }
            recipients.forEach { subscription ->
                sessions[subscription.first]?.takeIf { it.authenticated }?.let { session ->
                    val json = String(value, Charsets.UTF_8)
                    if (requestId != null || publishedEndpoints[subscription.first] != json) {
                        if (enqueueSecure(subscription.first, session, JSONObject(json)) && requestId == null)
                            publishedEndpoints[subscription.first] = json
                    }
                }
            }
        }
    }

    @SuppressLint("MissingPermission")
    private fun sendUpdate(
        device: android.bluetooth.BluetoothDevice,
        item: BluetoothGattCharacteristic,
        confirm: Boolean,
        value: ByteArray
    ) {
        if (!indicationInFlight.add(device)) return
        val accepted = if (Build.VERSION.SDK_INT >= 33) {
            server?.notifyCharacteristicChanged(device, item, confirm, value) ==
                BluetoothStatusCodes.SUCCESS
        } else {
            @Suppress("DEPRECATION")
            item.value = value
            @Suppress("DEPRECATION")
            server?.notifyCharacteristicChanged(device, item, confirm) == true
        }
        if (sessions[device]?.authenticated != true) android.util.Log.i("DroidMirrorNotifications", "Handshake indication: accepted=$accepted bytes=${value.size}")
        if (!accepted) {
            android.util.Log.w("DroidMirrorNotifications", "Bluetooth indication was rejected; resetting notification session")
            indicationInFlight.remove(device); revokeSession(device)
        }
    }

    @Synchronized
    private fun enqueue(device: android.bluetooth.BluetoothDevice, value: ByteArray) {
        if (subscribed[device] != true) return
        val queue = pendingIndication.getOrPut(device) { java.util.ArrayDeque() }
        // ATT attributes are limited to 512 bytes even when the negotiated MTU
        // is 517. Larger indications can be truncated by the central, breaking
        // reassembly of image-bearing notification messages.
        val frames = BleFragments.split(value, nextMessage++, BleLinkMtu.get(device.address) - 3)
        if (queue.sumOf { it.size } + frames.sumOf { it.size } > 262144) {
            revokeSession(device); return
        }
        queue.addAll(frames)
        drain(device)
    }

    @Synchronized
    private fun enqueueSecure(device: android.bluetooth.BluetoothDevice, session: BleSecureSession, value: JSONObject): Boolean {
        if (subscribed[device] != true || sessions[device] !== session || !session.authenticated) return false
        val queue = pendingMessages.getOrPut(device) { BleOutboundQueue() }
        // Preserve notification/update/removal order. Only file chunks yield to
        // control traffic; snapshots must not arrive after a newer tombstone.
        val bulk = value.optString("type") in setOf("cameraFrame", "clipboardFileChunk", "activityImageChunk", "appIconResult")
        val haptic = value.optString("type") == "haptic"
        if (!queue.append(value.toString(), bulk, android.os.SystemClock.elapsedRealtime(), haptic || value.optString("type") in setOf("pong", "appLaunchResult", "clipboardFilePrepareReady", "clipboardBulkOffer", "clipboardIrohOffer", "clipboardFileStop"),
                if (value.optString("type") == "notification" && value.optBoolean("activity") && !value.optBoolean("snapshot")) value.optString("id") else null,
                if (haptic) 200L else 60000L)) {
            if (value.optString("type") in setOf("cameraFrame", "activityImageChunk", "activityImageManifest", "appIconResult", "appCatalogResult")) return false
            if (haptic) return false // Optional feedback must not revoke a healthy mirror link.
            revokeSession(device)
            return false
        }
        drain(device)
        return sessions[device] === session
    }

    @Synchronized
    private fun drain(device: android.bluetooth.BluetoothDevice) {
        if (indicationInFlight.contains(device)) return
        val frames = pendingIndication.getOrPut(device) { java.util.ArrayDeque() }
        if (frames.isEmpty()) {
            val json = pendingMessages[device]?.next(android.os.SystemClock.elapsedRealtime()) ?: return
            val session = sessions[device]?.takeIf { it.authenticated } ?: return
            val sealed = runCatching {
                var message = JSONObject(json)
                val preparedAt = android.os.SystemClock.elapsedRealtime()
                if (message.optString("type") == "mediaState" && message.optBoolean("active")) message = MediaPositionTiming.advance(message, preparedAt)
                if (message.optString("type") == "notification" && message.optBoolean("chronometer") &&
                    message.has("clockSampleElapsedMs")) {
                    message.put("clockOffsetMs", NotificationClock.offsetAtSend(message.getLong("clockOffsetMs"),
                        message.getLong("clockSampleElapsedMs"), preparedAt))
                    message.remove("clockSampleElapsedMs")
                }
                ActivityEmbeddedTimers.prepareToSend(message, preparedAt)
                val wire = activityDeltas.getOrPut(device) { ActivityDeltas() }.encode(message, preparedAt)
                val fields = wire.optJSONObject("set")
                if (wire.optString("type") == "pong" ||
                    (wire.optString("type") == "notification" && (wire.optBoolean("chronometer") || wire.has("embeddedTimers"))) ||
                    (wire.optString("type") == "activityPatch" && (fields?.has("clockOffsetMs") == true || fields?.has("embeddedTimers") == true))) {
                    wire.put("clockSentElapsedMs", if (wire.optString("type") == "pong") android.os.SystemClock.elapsedRealtime() else preparedAt)
                }
                session.seal(wire)
            }.getOrElse { revokeSession(device); return }
            frames.addAll(BleFragments.split(sealed, nextMessage++, BleLinkMtu.get(device.address) - 3))
        }
        val frame = frames.pollFirst() ?: return
        characteristic?.let { sendUpdate(device, it, !notificationMode.contains(device), frame) }
    }

    @Synchronized
    fun sendEvent(value: JSONObject) {
        sessions.entries.filter { it.value.authenticated }.forEach { (device, session) ->
            runCatching { enqueueSecure(device, session, value) }.onFailure { revokeSession(device) }
        }
    }
    @Synchronized
    fun canForwardHaptics(): Boolean = sessions.any { (device, session) ->
        session.authenticated && subscribed[device] == true
    }

    @Synchronized
    private fun payload(requestId: Long? = null): ByteArray {
        val current = endpoint()
        if (current?.port != publishedPort) {
            publishedPort = current?.port
            revision += 1
        }
        val json = if (current == null) {
            JSONObject().put("error", "Port is not ready; enable Wireless debugging and refresh ADB endpoint")
        } else {
            JSONObject().put("port", current.port).apply {
                current.tailscaleIp?.let { put("ip", it) }
            }
        }
        json.put("revision", revision)
        requestId?.let { json.put("request", it) }
        return json.toString().toByteArray(Charsets.UTF_8)
    }

    @Synchronized
    private fun revokeSession(device: android.bluetooth.BluetoothDevice) {
        ++hotspotEpoch
        if (cameraDevice == device) { cameraDevice = null; ContinuityCameraService.disconnected() }
        // GATT services share the physical link with mirroring input. Revoking a
        // notification session must not disconnect that other authenticated service.
        if (mediaSubscribers.remove(device)) refreshMedia()
        if (bulkTestDevice == device) { bulkTestDevice = null; onBulkTest(null, ++bulkTestGeneration) }
        linkSubscribers.remove(device)
        if (taskSubscribers.remove(device) != null) refreshTasks()
        presencePeers.remove(device)?.let { computer -> if (computer !in presencePeers.values) onPresence(computer, false) }
        if (clipboardSubscribers.remove(device) != null || clipboardDevice == device) {
            sessions.remove(device) // the owner election below must not pick this device
            refreshClipboard()
        }
        notificationMode.remove(device)
        subscribed.remove(device)
        indicationInFlight.remove(device)
        pendingIndication.remove(device)
        pendingMessages.remove(device); activityDeltas.remove(device)
        publishedEndpoints.remove(device)
        sessions.remove(device)
        fragments.remove(device)
    }

    @SuppressLint("MissingPermission")
    fun revokeClients() {
        connected.toList().forEach { device ->
            runCatching { revokeSession(device) }
        }
    }
    @Synchronized fun revokeTrust() {
        presencePeers.clear()
        onPresenceReset()
        notificationMode.clear()
        publishedEndpoints.clear()
        sessions.clear(); fragments.clear(); pendingIndication.clear(); pendingMessages.clear(); activityDeltas.clear()
        revokeClients()
    }

    private val callback = object : BluetoothGattServerCallback() {
        override fun onConnectionStateChange(
            device: android.bluetooth.BluetoothDevice,
            status: Int,
            newState: Int
        ): Unit = synchronized(this@BlePeripheral) {
            if (newState == BluetoothProfile.STATE_CONNECTED) {
                // Two computers, each possibly with a stale link during reconnects.
                if (connected.size >= 2 * app.droidmirror.bluetooth.ComputerPeers.MAXIMUM) { revokeSession(device); return }
                connected += device
                android.os.Handler(android.os.Looper.getMainLooper()).postDelayed({
                    if (connected.contains(device) && subscribed[device] == true
                        && sessions[device]?.authenticated != true) revokeSession(device)
                }, 15000)
            }
            else if (newState == BluetoothProfile.STATE_DISCONNECTED) {
                revokeSession(device)
                BleLinkMtu.disconnected(device.address)
                connected -= device
                notificationMode.remove(device)
                subscribed.remove(device)
                indicationInFlight.remove(device)
                pendingIndication.remove(device)
                pendingMessages.remove(device); activityDeltas.remove(device)
                publishedEndpoints.remove(device)
        sessions.remove(device); fragments.remove(device)
            }
            Unit
        }

        override fun onPhyUpdate(device: android.bluetooth.BluetoothDevice, txPhy: Int, rxPhy: Int, status: Int) {
            if (device == clipboardDevice) android.util.Log.i("DroidMirrorClipboard", "BLE PHY tx=$txPhy rx=$rxPhy status=$status")
        }

        override fun onNotificationSent(device: android.bluetooth.BluetoothDevice, status: Int) {
            if (sessions[device]?.authenticated != true) android.util.Log.i("DroidMirrorNotifications", "Handshake indication completed: status=$status")
            indicationInFlight.remove(device)
            if (status == BluetoothGatt.GATT_SUCCESS) drain(device) else revokeSession(device)
        }

        override fun onMtuChanged(device: android.bluetooth.BluetoothDevice, value: Int) {
            BleLinkMtu.negotiated(device.address, value)
        }

        @SuppressLint("MissingPermission")
        override fun onCharacteristicReadRequest(
            device: android.bluetooth.BluetoothDevice,
            requestId: Int,
            offset: Int,
            item: BluetoothGattCharacteristic
        ) {
            server?.sendResponse(device, requestId, BluetoothGatt.GATT_READ_NOT_PERMITTED, 0, null)
        }

        @SuppressLint("MissingPermission")
        override fun onCharacteristicWriteRequest(
            device: android.bluetooth.BluetoothDevice,
            requestId: Int,
            item: BluetoothGattCharacteristic,
            preparedWrite: Boolean,
            responseNeeded: Boolean,
            offset: Int,
            value: ByteArray
        ) {
            if (item.uuid == BULK_TEST_UUID) {
                synchronized(this@BlePeripheral) {
                    if (!preparedWrite && offset == 0 && device == bulkTestDevice && bulkTestAuthorized(bulkTestGeneration))
                        onBulkTestData(value.copyOf(), bulkTestGeneration)
                }
                if (responseNeeded) server?.sendResponse(device, requestId, BluetoothGatt.GATT_FAILURE, 0, null)
                return
            }
            val valid = !preparedWrite && offset == 0 && subscribed[device] == true && value.size > 9 && value[0] == 0xd2.toByte()
            // A service joining an existing physical link can miss its MTU
            // callback. A non-prepared write proves the usable link capacity;
            // share it with input instead of flooding this link with 20-byte
            // fragments during every notification reauthentication/snapshot.
            if (valid) BleLinkMtu.observedWrite(device.address, value.size)
            if (responseNeeded) server?.sendResponse(
                device,
                requestId,
                if (valid) BluetoothGatt.GATT_SUCCESS else BluetoothGatt.GATT_FAILURE,
                0,
                null
            )
            if (sessions[device]?.authenticated != true) android.util.Log.i("DroidMirrorNotifications",
                "Handshake write: valid=$valid bytes=${value.size}")
            if (valid) {
                synchronized(this@BlePeripheral) {
                    runCatching {
                        val data = fragments.getOrPut(device) { BleFragments() }.accept(value) ?: return
                        val objectValue = JSONObject(String(data, Charsets.UTF_8))
                        val session = sessions[device] ?: run {
                            require(objectValue.optString("type") == "hello") { "No session" }
                            val (computer, key) = requireNotNull(BleTrust.computerFor(context, objectValue, device.address)) { "Unknown computer" }
                            BleSecureSession(key, computer).also { sessions[device] = it }
                        }
                        when {
                            objectValue.optString("type") == "hello" -> {
                                if (cameraDevice == device) { cameraDevice = null; ContinuityCameraService.disconnected() }
                                if (bulkTestDevice == device) { bulkTestDevice = null; onBulkTest(null, ++bulkTestGeneration) }
                                ++hotspotEpoch
                                android.util.Log.i("DroidMirrorNotifications", "Sending authentication challenge")
                                enqueue(device, session.hello(objectValue).toString().toByteArray())
                            }
                            objectValue.optString("type") == "finish" -> {
                                session.finish(objectValue)
                                BleTrust.authenticated(device.address)
                                // One live background session per computer: a reconnect replaces a stale one.
                                sessions.entries.filter { (other, existing) -> other != device && existing.authenticated && existing.computer == session.computer }
                                    .map { it.key }.forEach { revokeSession(it) }
                                val firstForComputer = session.computer !in presencePeers.values
                                presencePeers[device] = session.computer
                                if (firstForComputer) onPresence(session.computer, true)
                                android.util.Log.i("DroidMirrorNotifications", "BLE notification session authenticated")
                                enqueueSecure(device, session, JSONObject().put("type", "ready").put("activityImages", 1).put("watchCompanion", 1).put("sessionHealth", 1).put("changePush", 1).put("clipboard", 1).put("clipboardFiles", 1).put("apkInstall", if (app.droidmirror.bluetooth.PackageInstallClient.available()) 1 else 0).put("clipboardDownloads", if (Build.VERSION.SDK_INT >= 29) 1 else 0).put("clipboardBulk", if (Build.VERSION.SDK_INT >= 29) 1 else 0).put("clipboardProgress", 1).put("clipboardIroh", 1).put("bulkTest", if (Build.VERSION.SDK_INT >= 29) 1 else 0).put("taskUrls", 1).put("appLibrary", 1).put("appLibraryIroh", 1).put("linkSharing", 1).put("media", 1)
                                    .put("focusSync", 1).put("hotspot", if (Build.VERSION.SDK_INT >= 30) 2 else 0))
                                publishedEndpoints.remove(device)
                                publish(device)
                            }
                            else -> {
                                val command = session.open(objectValue)
                                when (command.optString("type")) {
                                    "cameraStart", "cameraLease", "cameraStop", "cameraFrameAck", "cameraKeyframe" -> {
                                        if (cameraDevice == null && command.optString("type") == "cameraStart") cameraDevice = device
                                        if (cameraDevice == device) {
                                            val valid = { synchronized(this@BlePeripheral) {
                                                cameraDevice == device && sessions[device] === session && session.authenticated
                                            } }
                                            ContinuityCameraService.command(context, session.computer, command, valid) { value -> synchronized(this@BlePeripheral) {
                                                // Bound video backlog; optional camera traffic never revokes BLE.
                                                valid() && (pendingMessages[device]?.bytes ?: 0) < 180000 && enqueueSecure(device, session, value)
                                            } }
                                        }
                                    }

                                    "watchMacState", "watchMacTicket", "watchFindResult" -> {
                                        // Watch commands route only through this exact authenticated session
                                        // of a trusted computer; the watch follows the most recent one.
                                        run {
                                            val valid = { synchronized(this@BlePeripheral) {
                                                sessions[device] === session && session.authenticated &&
                                                    app.droidmirror.bluetooth.ComputerPeers.contains(context, session.computer)
                                            } }
                                            onWatchEvent(command, valid, { value -> synchronized(this@BlePeripheral) {
                                                if (valid()) runCatching { enqueueSecure(device, session, value) }.getOrElse { revokeSession(device); false }
                                                else false
                                            } })
                                        }
                                    }
                                    "focusSet", "focusQuery" -> {
                                        onFocus(command, { synchronized(this@BlePeripheral) {
                                            sessions[device] === session && session.authenticated
                                        } }, { result -> synchronized(this@BlePeripheral) {
                                            if (sessions[device] === session && session.authenticated) enqueueSecure(device, session, result)
                                        } })
                                    }
                                    "hotspotStart", "hotspotStop" -> {
                                        val request = command.optString("request")
                                        require(request.matches(Regex("[A-Za-z0-9-]{1,64}")))
                                        val epoch = hotspotEpoch
                                        onHotspotToggle(command.optString("type") == "hotspotStart", { synchronized(this@BlePeripheral) {
                                            hotspotEpoch == epoch && sessions[device] === session && session.authenticated
                                        } }) { result -> synchronized(this@BlePeripheral) {
                                            // A reply can only return to the original authenticated session.
                                            if (hotspotEpoch == epoch && sessions[device] === session && session.authenticated) {
                                                runCatching { enqueueSecure(device, session, result.put("type", "hotspotResult").put("request", request)) }
                                                    .onFailure { revokeSession(device) }
                                            }
                                        } }
                                    }
                                    "linkSubscribe" -> { linkSubscribers.remove(device); linkSubscribers[device] = session }
                                    "shareLinkResult" -> {
                                        if (linkSubscribers[device] === session) {
                                            onShareLinkResult(command.optString("request"), command.optBoolean("success"))
                                        }
                                    }
                                    "openLink" -> {
                                        val request = command.optString("request")
                                        require(runCatching { UUID.fromString(request) }.isSuccess)
                                        val url = command.optString("url")
                                        val epoch = hotspotEpoch
                                        onOpenLink(url, { synchronized(this@BlePeripheral) {
                                            hotspotEpoch == epoch && sessions[device] === session && session.authenticated
                                        } }) { success -> synchronized(this@BlePeripheral) {
                                            if (hotspotEpoch == epoch && sessions[device] === session && session.authenticated) {
                                                runCatching { enqueueSecure(device, session, JSONObject().put("type", "openLinkResult")
                                                    .put("request", request).put("success", success)) }
                                                    .onFailure { revokeSession(device) }
                                            }
                                        } }
                                    }
                                    "ping" -> {
                                        val request = command.getString("request")
                                        require(request.matches(Regex("[A-Za-z0-9-]{1,64}")))
                                        enqueueSecure(device, session, JSONObject().put("type", "pong").put("request", request)
                                            .put("clockReceivedElapsedMs", android.os.SystemClock.elapsedRealtime()))
                                    }
                                    "get" -> publish(device, command.optLong("request"))
                                    "state" -> onCommand(if (command.optBoolean("connected")) "CONNECTED" else "DISCONNECTED")
                                    "subscribe" -> {
                                        activityDeltas.getOrPut(device) { ActivityDeltas() }.enabled = command.optInt("activityDeltas") == 1
                                        val snapshot = PhoneNotifications.live?.snapshot()
                                        snapshot?.forEach { enqueueSecure(device, session, it) }
                                    }
                                    "bulkTestOpen" -> {
                                        require(Build.VERSION.SDK_INT >= 29)
                                        require(command.optString("id").matches(Regex("[A-Fa-f0-9-]{36}")))
                                        require(command.optInt("bytes") in 1..4_000_000 && command.optInt("window", -1) in setOf(0, 1, 8, 32))
                                        require(command.optString("transport") in setOf("l2cap", "gatt", "iroh"))
                                        bulkTestDevice = device; bulkTestId = command.getString("id")
                                        onBulkTest(command, ++bulkTestGeneration)
                                    }
                                    "bulkTestStop" -> if (bulkTestDevice == device && command.optString("id") == bulkTestId) {
                                        bulkTestDevice = null; onBulkTest(null, ++bulkTestGeneration)
                                    }
                                    "clipboardSubscribe" -> {
                                        // The latest subscriber becomes the file-transfer owner.
                                        clipboardSubscribers.remove(device)
                                        if (command.optBoolean("enabled")) {
                                            clipboardSubscribers[device] = command
                                            refreshClipboard(force = true)
                                        } else refreshClipboard()
                                    }
                                    "clipboardFilePrepare", "clipboardFilePrepareEnd" -> {
                                        require(command.optString("id").matches(Regex("[a-fA-F0-9-]{36}")))
                                        if (clipboardDevice == device) onClipboardPreparation(command, clipboardGeneration)
                                    }
                                    "clipboardIrohOpen" -> {
                                        if (clipboardDevice == device && clipboardBulkRequested) onClipboardIrohOpen(clipboardGeneration, command.optBoolean("retry"))
                                    }
                                    "clipboardBulkOpen" -> {
                                        if (clipboardDevice == device && clipboardBulkRequested) onClipboardBulkOpen(clipboardGeneration)
                                    }
                                    "clipboardFileBegin", "clipboardFileChunk", "clipboardFileAck", "clipboardFileCancel" -> {
                                        if (clipboardDevice == device && !clipboardBulkRequested) onClipboardFile(command)
                                    }
                                    "clipboardSet" -> {
                                        if (clipboardSubscribers.containsKey(device)) onClipboardText(command.optString("text"))
                                    }
                                    "mediaSubscribe" -> {
                                        val joined = command.optBoolean("enabled") && mediaSubscribers.add(device)
                                        if (!command.optBoolean("enabled")) mediaSubscribers.remove(device)
                                        refreshMedia(force = joined)
                                    }
                                    "mediaState", "mediaQueue", "mediaCommand", "mediaVolume", "mediaArtworkRequest", "mediaArtworkChunk" -> {
                                        val generation = mediaGeneration
                                        if (device in mediaSubscribers) onMediaEvent(command) {
                                            synchronized(this@BlePeripheral) {
                                                mediaGeneration == generation && device in mediaSubscribers &&
                                                    sessions[device] === session && session.authenticated
                                            }
                                        }
                                    }
                                    "taskSubscribe" -> {
                                        if (command.optBoolean("enabled")) taskSubscribers[device] = command.optBoolean("changeOnly")
                                        else taskSubscribers.remove(device)
                                        refreshTasks()
                                    }
                                    "appCatalogSubscribe" -> {
                                        val request = command.optString("request")
                                        require(request.matches(Regex("[A-Za-z0-9-]{1,64}")))
                                        onCatalogSubscription(device.address, { synchronized(this@BlePeripheral) {
                                            sessions[device] === session && session.authenticated
                                        } }) { result -> synchronized(this@BlePeripheral) {
                                            if (sessions[device] === session && session.authenticated) {
                                                runCatching { enqueueSecure(device, session, result.put("type", "appCatalogChanged").put("request", request)) }
                                            }
                                        } }
                                    }
                                    "appLibraryOffer", "appCatalogRequest", "appIconRequest", "appLaunch" -> {
                                        val request = command.optString("request")
                                        require(request.matches(Regex("[A-Za-z0-9-]{1,64}")))
                                        val replyType = when (command.optString("type")) {
                                            "appLibraryOffer" -> "appLibraryOfferResult"
                                            "appCatalogRequest" -> "appCatalogResult"
                                            "appIconRequest" -> "appIconResult"
                                            else -> "appLaunchResult"
                                        }
                                        onAppLibrary(session.computer, command, { synchronized(this@BlePeripheral) {
                                            sessions[device] === session && session.authenticated
                                        } }) { result -> synchronized(this@BlePeripheral) {
                                            if (sessions[device] === session && session.authenticated) {
                                                runCatching { enqueueSecure(device, session, result.put("type", replyType).put("request", request)) }
                                            }
                                        } }
                                    }
                                    "activityImageManifestRequest" -> {
                                        val request = command.optString("request")
                                        require(request.matches(Regex("[A-Za-z0-9-]{1,64}")))
                                        PhoneNotifications.live?.imageManifest(command) { result -> synchronized(this@BlePeripheral) {
                                            if (sessions[device] === session && session.authenticated) {
                                                enqueueSecure(device, session, result.put("type", "activityImageManifest").put("request", request))
                                            }
                                        } } ?: enqueueSecure(device, session, JSONObject().put("type", "activityImageManifest").put("request", request).put("success", false))
                                    }
                                    "activityImageRequest" -> {
                                        val result = PhoneNotifications.live?.imageChunk(command) ?: JSONObject().put("success", false)
                                        enqueueSecure(device, session, result.put("type", "activityImageChunk").put("request", command.optString("request")))
                                    }
                                    "dismiss" -> {
                                        val success = PhoneNotifications.live?.dismiss(command) == true
                                        enqueueSecure(device, session, JSONObject().put("type", "dismissResult")
                                            .put("request", command.optString("request")).put("success", success))
                                    }
                                    "action" -> {
                                        val listener = PhoneNotifications.live
                                        if (listener != null && (command.optString("action") == "open" || listener.requiresMirror(command))) {
                                            listener.openAfterUnlock(command, { synchronized(this@BlePeripheral) {
                                                sessions[device] === session && session.authenticated
                                            } }) { success -> synchronized(this@BlePeripheral) {
                                                if (sessions[device] === session && session.authenticated) {
                                                    runCatching { enqueueSecure(device, session, JSONObject().put("type", "actionResult")
                                                        .put("request", command.optString("request")).put("success", success)) }
                                                        .onFailure { revokeSession(device) }
                                                }
                                            } }
                                        } else {
                                            val success = listener?.perform(command) == true
                                            enqueueSecure(device, session, JSONObject().put("type", "actionResult").put("request", command.optString("request")).put("success", success))
                                        }
                                    }
                                    else -> error("Invalid command")
                                }
                            }
                        }
                    }.onFailure {
                        android.util.Log.w("DroidMirrorNotifications", "Notification handshake/command failed: ${it.javaClass.simpleName}")
                        revokeSession(device)
                    }
                }
            }
        }

        @SuppressLint("MissingPermission")
        override fun onDescriptorReadRequest(
            device: android.bluetooth.BluetoothDevice,
            requestId: Int,
            offset: Int,
            descriptor: BluetoothGattDescriptor
        ) {
            // CoreBluetooth may read the CCC while discovering this service.
            // Leaving that ATT request unanswered stalls discovery until timeout.
            val value = if (notificationMode.contains(device)) BluetoothGattDescriptor.ENABLE_NOTIFICATION_VALUE
                else if (subscribed[device] == true) BluetoothGattDescriptor.ENABLE_INDICATION_VALUE
                else BluetoothGattDescriptor.DISABLE_NOTIFICATION_VALUE
            val status = when {
                descriptor.uuid != CCC_UUID -> BluetoothGatt.GATT_REQUEST_NOT_SUPPORTED
                offset < 0 || offset > value.size -> BluetoothGatt.GATT_INVALID_OFFSET
                else -> BluetoothGatt.GATT_SUCCESS
            }
            server?.sendResponse(device, requestId, status, offset,
                if (status == BluetoothGatt.GATT_SUCCESS) value.copyOfRange(offset, value.size) else null)
        }

        @SuppressLint("MissingPermission")
        override fun onDescriptorWriteRequest(
            device: android.bluetooth.BluetoothDevice,
            requestId: Int,
            descriptor: BluetoothGattDescriptor,
            preparedWrite: Boolean,
            responseNeeded: Boolean,
            offset: Int,
            value: ByteArray
        ) {
            val valid = descriptor.uuid == CCC_UUID && !preparedWrite && offset == 0 &&
                (value.contentEquals(BluetoothGattDescriptor.ENABLE_INDICATION_VALUE) ||
                 value.contentEquals(BluetoothGattDescriptor.ENABLE_NOTIFICATION_VALUE) ||
                 value.contentEquals(BluetoothGattDescriptor.DISABLE_NOTIFICATION_VALUE))
            android.util.Log.i("DroidMirrorNotifications", "Notification subscription: valid=$valid enabled=${!value.contentEquals(BluetoothGattDescriptor.DISABLE_NOTIFICATION_VALUE)} confirmed=${value.contentEquals(BluetoothGattDescriptor.ENABLE_INDICATION_VALUE)}")
            if (valid) {
                synchronized(this@BlePeripheral) {
                    // Core Bluetooth can resubscribe without disconnecting the
                    // shared physical link. Its next hello belongs to a new
                    // authenticated session, not the old session's nonce state.
                    revokeSession(device)
                    if (!value.contentEquals(BluetoothGattDescriptor.DISABLE_NOTIFICATION_VALUE)) {
                        subscribed[device] = true
                        if (value.contentEquals(BluetoothGattDescriptor.ENABLE_NOTIFICATION_VALUE)) notificationMode.add(device)
                    }
                }
            }
            if (responseNeeded) server?.sendResponse(
                device, requestId, if (valid) BluetoothGatt.GATT_SUCCESS else BluetoothGatt.GATT_FAILURE, 0, null
            )
        }
    }
}
