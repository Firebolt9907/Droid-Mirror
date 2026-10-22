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
    private val onPresence: (String, Boolean) -> Unit = { _, _ -> },
    private val onPresenceReset: () -> Unit = {},
    private val onCommand: (String) -> Unit = {},
    private val onClipboardSubscription: (Boolean, Long, Boolean) -> Unit = { _, _, _ -> },
    private val onClipboardText: (String) -> Unit = {},
    private val onClipboardFile: (JSONObject) -> Unit = {},
    private val onMediaSubscription: (Boolean, Long) -> Unit = { _, _ -> },
    private val onMediaEvent: (JSONObject, () -> Boolean) -> Unit = { _, _ -> },
    private val onTaskSubscription: (Boolean, Long) -> Unit = { _, _ -> },
    private val onOpenLink: (String, () -> Boolean, (Boolean) -> Unit) -> Unit = { _, _, reply -> reply(false) },
    private val onShareLinkResult: (String, Boolean) -> Unit = { _, _ -> },
    private val onHotspotToggle: (Boolean, () -> Boolean, (JSONObject) -> Unit) -> Unit = { _, _, reply -> reply(JSONObject().put("status", "unsupported")) }
) {
    companion object {
        val SERVICE_UUID: UUID = UUID.fromString("7e57b000-9a6b-4c5d-8e7f-102030405060")
        val ENDPOINT_UUID: UUID = UUID.fromString("7e57b001-9a6b-4c5d-8e7f-102030405060")
        private val CCC_UUID: UUID = UUID.fromString("00002902-0000-1000-8000-00805f9b34fb")
    }

    private val manager = context.getSystemService(BluetoothManager::class.java)
    private val adapter: BluetoothAdapter? get() = manager.adapter
    private var server: BluetoothGattServer? = null
    private var characteristic: BluetoothGattCharacteristic? = null
    private val presencePeers = ConcurrentHashMap.newKeySet<android.bluetooth.BluetoothDevice>()
    private val connected = ConcurrentHashMap.newKeySet<android.bluetooth.BluetoothDevice>()
    private val subscribed = ConcurrentHashMap<android.bluetooth.BluetoothDevice, Boolean>()
    private val indicationInFlight = ConcurrentHashMap.newKeySet<android.bluetooth.BluetoothDevice>()
    private val notificationMode = ConcurrentHashMap.newKeySet<android.bluetooth.BluetoothDevice>()
    private val pendingIndication = ConcurrentHashMap<android.bluetooth.BluetoothDevice, java.util.ArrayDeque<ByteArray>>()
    private val pendingMessages = ConcurrentHashMap<android.bluetooth.BluetoothDevice, BleOutboundQueue>()
    private val sessions = ConcurrentHashMap<android.bluetooth.BluetoothDevice, BleSecureSession>()
    private val fragments = ConcurrentHashMap<android.bluetooth.BluetoothDevice, BleFragments>()
    private var nextMessage = 1
    private var advertiser: android.bluetooth.le.BluetoothLeAdvertiser? = null
    private var advertiseCallback: AdvertiseCallback? = null
    private var publishedPort: Int? = null
    private var revision = 0L
    private var clipboardDevice: android.bluetooth.BluetoothDevice? = null
    private var clipboardGeneration = 0L
    private var linkDevice: android.bluetooth.BluetoothDevice? = null
    private var linkSession: BleSecureSession? = null
    private var taskDevice: android.bluetooth.BluetoothDevice? = null
    private var taskGeneration = 0L
    private var mediaDevice: android.bluetooth.BluetoothDevice? = null
    private var mediaGeneration = 0L
    private var hotspotEpoch = 0L

    @Synchronized fun shareLink(url: String, request: String): Boolean {
        val device = linkDevice ?: return false
        val session = sessions[device]?.takeIf { it.authenticated && it === linkSession } ?: return false
        return runCatching {
            enqueueSecure(device, session, JSONObject().put("type", "shareLink").put("url", url).put("request", request))
        }.getOrElse { revokeSession(device); false }
    }

    @Synchronized fun sendMediaEvent(value: JSONObject, generation: Long) {
        if (generation != mediaGeneration) return
        val device = mediaDevice ?: return
        val session = sessions[device]?.takeIf { it.authenticated } ?: return
        runCatching { enqueueSecure(device, session, value) }.onFailure { revokeSession(device) }
    }

    @Synchronized fun sendTaskEvent(value: JSONObject, generation: Long) {
        if (generation != taskGeneration) return
        val device = taskDevice ?: return
        val session = sessions[device]?.takeIf { it.authenticated } ?: return
        runCatching { enqueueSecure(device, session, value) }.onFailure { revokeSession(device) }
    }

    @Synchronized fun sendClipboardEvent(value: JSONObject, generation: Long) {
        if (generation != clipboardGeneration) return
        val device = clipboardDevice ?: return
        val session = sessions[device]?.takeIf { it.authenticated } ?: return
        runCatching { enqueueSecure(device, session, value) }.onFailure { revokeSession(device) }
    }

    @SuppressLint("MissingPermission")
    fun start(onStatus: (String) -> Unit) {
        stop()
        val discovery = runCatching {
            app.droidmirror.bluetooth.PairingKeys.discovery(requireNotNull(BleTrust.key(context)))
        }.getOrNull() ?: return onStatus("Select and pair a Mac before enabling BLE")
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
        ).apply { addCharacteristic(characteristic) }
        gatt.addService(service)

        val callback = object : AdvertiseCallback() {
            override fun onStartSuccess(settingsInEffect: AdvertiseSettings?) =
                onStatus("BLE ready — waiting for Mac")

            override fun onStartFailure(errorCode: Int) =
                onStatus("BLE advertising failed: $errorCode")
        }
        advertiseCallback = callback
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

    @SuppressLint("MissingPermission")
    @Synchronized fun stop() {
        presencePeers.clear()
        onPresenceReset()
        ++hotspotEpoch
        advertiseCallback?.let { advertiser?.stopAdvertising(it) }
        advertiseCallback = null
        advertiser = null
        mediaDevice = null
        onMediaSubscription(false, ++mediaGeneration)
        clipboardDevice = null
        onClipboardSubscription(false, ++clipboardGeneration, false)
        taskDevice = null
        onTaskSubscription(false, ++taskGeneration)
        server?.close()
        server = null
        connected.clear()
        subscribed.clear()
        indicationInFlight.clear()
        pendingMessages.clear()
        notificationMode.clear()
        pendingIndication.clear()
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
                    enqueueSecure(subscription.first, session, JSONObject(String(value, Charsets.UTF_8)))
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
        val bulk = value.optString("type") == "clipboardFileChunk"
        if (!queue.append(value.toString(), bulk, android.os.SystemClock.elapsedRealtime(), value.optString("type") == "pong")) {
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
            val sealed = runCatching { session.seal(JSONObject(json)) }.getOrElse { revokeSession(device); return }
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
        // GATT services share the physical link with mirroring input. Revoking a
        // notification session must not disconnect that other authenticated service.
        if (mediaDevice == device) { mediaDevice = null; onMediaSubscription(false, ++mediaGeneration) }
        if (clipboardDevice == device) { clipboardDevice = null; onClipboardSubscription(false, ++clipboardGeneration, false) }
        if (taskDevice == device) { taskDevice = null; onTaskSubscription(false, ++taskGeneration) }
        notificationMode.remove(device)
        subscribed.remove(device)
        indicationInFlight.remove(device)
        pendingIndication.remove(device)
        pendingMessages.remove(device)
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
        sessions.clear(); fragments.clear(); pendingIndication.clear(); pendingMessages.clear()
        revokeClients()
    }

    private val callback = object : BluetoothGattServerCallback() {
        override fun onConnectionStateChange(
            device: android.bluetooth.BluetoothDevice,
            status: Int,
            newState: Int
        ): Unit = synchronized(this@BlePeripheral) {
            if (newState == BluetoothProfile.STATE_CONNECTED) {
                if (connected.size >= 4) { revokeSession(device); return }
                connected += device
                android.os.Handler(android.os.Looper.getMainLooper()).postDelayed({
                    if (connected.contains(device) && subscribed[device] == true
                        && sessions[device]?.authenticated != true) revokeSession(device)
                }, 15000)
            }
            else if (newState == BluetoothProfile.STATE_DISCONNECTED) {
                if (presencePeers.remove(device)) onPresence(device.address, false)
                revokeSession(device)
                BleLinkMtu.disconnected(device.address)
                connected -= device
                notificationMode.remove(device)
                subscribed.remove(device)
                indicationInFlight.remove(device)
                pendingIndication.remove(device)
                pendingMessages.remove(device)
                sessions.remove(device); fragments.remove(device)
            }
            Unit
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
                        val session = sessions[device] ?: BleSecureSession(requireNotNull(BleTrust.key(context))).also { sessions[device] = it }
                        when {
                            objectValue.optString("type") == "hello" -> {
                                ++hotspotEpoch
                                android.util.Log.i("DroidMirrorNotifications", "Sending authentication challenge")
                                enqueue(device, session.hello(objectValue).toString().toByteArray())
                            }
                            objectValue.optString("type") == "finish" -> {
                                session.finish(objectValue)
                                presencePeers.add(device)
                                onPresence(device.address, true)
                                android.util.Log.i("DroidMirrorNotifications", "BLE notification session authenticated")
                                enqueueSecure(device, session, JSONObject().put("type", "ready").put("watchCompanion", 1).put("sessionHealth", 1).put("clipboard", 1).put("clipboardFiles", 1).put("taskUrls", 1).put("linkSharing", 1).put("media", 1)
                                    .put("hotspot", if (Build.VERSION.SDK_INT >= 30) 2 else 0))
                            }
                            else -> {
                                val command = session.open(objectValue)
                                when (command.optString("type")) {
                                    "watchMacState", "watchFindResult" -> {
                                        // Watch commands may only route to the selected capture Mac and this exact BLE session.
                                        if (device.address == context.getSharedPreferences("ready", Context.MODE_PRIVATE).getString("peer", "")) {
                                            val valid = { synchronized(this@BlePeripheral) {
                                                sessions[device] === session && session.authenticated &&
                                                    device.address == context.getSharedPreferences("ready", Context.MODE_PRIVATE).getString("peer", "")
                                            } }
                                            onWatchEvent(command, valid, { value -> synchronized(this@BlePeripheral) {
                                                if (valid()) runCatching { enqueueSecure(device, session, value) }.getOrElse { revokeSession(device); false }
                                                else false
                                            } })
                                        }
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
                                    "linkSubscribe" -> { linkDevice = device; linkSession = session }
                                    "shareLinkResult" -> {
                                        if (device == linkDevice && session === linkSession) {
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
                                        enqueueSecure(device, session, JSONObject().put("type", "pong").put("request", request))
                                    }
                                    "get" -> publish(device, command.optLong("request"))
                                    "state" -> onCommand(if (command.optBoolean("connected")) "CONNECTED" else "DISCONNECTED")
                                    "subscribe" -> {
                                        val snapshot = PhoneNotifications.live?.snapshot()
                                        snapshot?.forEach { enqueueSecure(device, session, it) }
                                    }
                                    "clipboardSubscribe" -> {
                                        if (command.optBoolean("enabled")) {
                                            // One paired clipboard owner avoids cross-Mac forwarding.
                                            clipboardDevice = device
                                            onClipboardSubscription(true, ++clipboardGeneration, command.optBoolean("files"))
                                        } else if (clipboardDevice == device) {
                                            clipboardDevice = null
                                            onClipboardSubscription(false, ++clipboardGeneration, false)
                                        }
                                    }
                                    "clipboardFileBegin", "clipboardFileChunk", "clipboardFileAck", "clipboardFileCancel" -> {
                                        if (clipboardDevice == device) onClipboardFile(command)
                                    }
                                    "clipboardSet" -> {
                                        if (clipboardDevice == device) onClipboardText(command.optString("text"))
                                    }
                                    "mediaSubscribe" -> {
                                        if (command.optBoolean("enabled")) {
                                            mediaDevice = device
                                            onMediaSubscription(true, ++mediaGeneration)
                                        } else if (mediaDevice == device) {
                                            mediaDevice = null
                                            onMediaSubscription(false, ++mediaGeneration)
                                        }
                                    }
                                    "mediaState", "mediaQueue", "mediaCommand", "mediaArtworkRequest", "mediaArtworkChunk" -> {
                                        val generation = mediaGeneration
                                        if (mediaDevice == device) onMediaEvent(command) {
                                            synchronized(this@BlePeripheral) {
                                                mediaGeneration == generation && mediaDevice == device &&
                                                    sessions[device] === session && session.authenticated
                                            }
                                        }
                                    }
                                    "taskSubscribe" -> {
                                        if (command.optBoolean("enabled")) {
                                            taskDevice = device
                                            onTaskSubscription(true, ++taskGeneration)
                                        } else if (taskDevice == device) {
                                            taskDevice = null
                                            onTaskSubscription(false, ++taskGeneration)
                                        }
                                    }
                                    "dismiss" -> {
                                        val success = PhoneNotifications.live?.dismiss(command) == true
                                        enqueueSecure(device, session, JSONObject().put("type", "dismissResult")
                                            .put("request", command.optString("request")).put("success", success))
                                    }
                                    "action" -> {
                                        val listener = PhoneNotifications.live
                                        if (command.optString("action") == "open" && listener != null) {
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
