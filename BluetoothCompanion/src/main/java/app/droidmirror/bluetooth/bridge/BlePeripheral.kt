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
    private val onCommand: (String) -> Unit = {}
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
    private val connected = ConcurrentHashMap.newKeySet<android.bluetooth.BluetoothDevice>()
    private val subscribed = ConcurrentHashMap<android.bluetooth.BluetoothDevice, Boolean>()
    private val indicationInFlight = ConcurrentHashMap.newKeySet<android.bluetooth.BluetoothDevice>()
    private val pendingIndication = ConcurrentHashMap<android.bluetooth.BluetoothDevice, java.util.ArrayDeque<ByteArray>>()
    private val sessions = ConcurrentHashMap<android.bluetooth.BluetoothDevice, BleSecureSession>()
    private val fragments = ConcurrentHashMap<android.bluetooth.BluetoothDevice, BleFragments>()
    private val mtu = ConcurrentHashMap<android.bluetooth.BluetoothDevice, Int>()
    private var nextMessage = 1
    private var advertiser: android.bluetooth.le.BluetoothLeAdvertiser? = null
    private var advertiseCallback: AdvertiseCallback? = null
    private var publishedPort: Int? = null
    private var revision = 0L

    @SuppressLint("MissingPermission")
    fun start(onStatus: (String) -> Unit) {
        stop()
        val bluetooth = adapter ?: return onStatus("Bluetooth is unavailable")
        val bleAdvertiser = bluetooth.bluetoothLeAdvertiser
            ?: return onStatus("BLE advertising is unavailable")
        advertiser = bleAdvertiser
        val gatt = manager.openGattServer(context, callback)
            ?: return onStatus("Could not open BLE GATT server")
        server = gatt

        characteristic = BluetoothGattCharacteristic(
            ENDPOINT_UUID,
            BluetoothGattCharacteristic.PROPERTY_WRITE or
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
                .addServiceUuid(ParcelUuid(SERVICE_UUID))
                .build(),
            callback
        )
    }

    @SuppressLint("MissingPermission")
    fun stop() {
        advertiseCallback?.let { advertiser?.stopAdvertising(it) }
        advertiseCallback = null
        advertiser = null
        server?.close()
        server = null
        connected.clear()
        subscribed.clear()
        indicationInFlight.clear()
        pendingIndication.clear()
        sessions.clear(); fragments.clear(); mtu.clear()
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
                    enqueue(subscription.first, session.seal(JSONObject(String(value, Charsets.UTF_8))))
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
        val frames = BleFragments.split(value, nextMessage++, (mtu[device] ?: 23) - 3)
        if (queue.sumOf { it.size } + frames.sumOf { it.size } > 262144) {
            revokeSession(device); return
        }
        queue.addAll(frames)
        drain(device)
    }

    @Synchronized
    private fun drain(device: android.bluetooth.BluetoothDevice) {
        if (indicationInFlight.contains(device)) return
        val frame = pendingIndication[device]?.pollFirst() ?: return
        characteristic?.let { sendUpdate(device, it, true, frame) }
    }

    @Synchronized
    fun sendEvent(value: JSONObject) {
        sessions.entries.filter { it.value.authenticated }.forEach { (device, session) ->
            runCatching { enqueue(device, session.seal(value)) }.onFailure { revokeSession(device) }
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
        // GATT services share the physical link with mirroring input. Revoking a
        // notification session must not disconnect that other authenticated service.
        subscribed.remove(device)
        indicationInFlight.remove(device)
        pendingIndication.remove(device)
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
        sessions.clear(); fragments.clear(); pendingIndication.clear()
        revokeClients()
    }

    private val callback = object : BluetoothGattServerCallback() {
        override fun onConnectionStateChange(
            device: android.bluetooth.BluetoothDevice,
            status: Int,
            newState: Int
        ) {
            if (newState == BluetoothProfile.STATE_CONNECTED) {
                if (connected.size >= 4) { revokeSession(device); return }
                connected += device
                android.os.Handler(android.os.Looper.getMainLooper()).postDelayed({
                    if (connected.contains(device) && subscribed[device] == true
                        && sessions[device]?.authenticated != true) revokeSession(device)
                }, 15000)
            }
            else {
                BleLinkMtu.disconnected(device.address)
                connected -= device
                subscribed.remove(device)
                indicationInFlight.remove(device)
                pendingIndication.remove(device)
                sessions.remove(device); fragments.remove(device); mtu.remove(device)
            }
        }

        override fun onNotificationSent(device: android.bluetooth.BluetoothDevice, status: Int) {
            indicationInFlight.remove(device)
            if (status == BluetoothGatt.GATT_SUCCESS) drain(device) else revokeSession(device)
        }

        override fun onMtuChanged(device: android.bluetooth.BluetoothDevice, value: Int) {
            mtu[device] = value.coerceIn(23, 517)
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
            if (responseNeeded) server?.sendResponse(
                device,
                requestId,
                if (valid) BluetoothGatt.GATT_SUCCESS else BluetoothGatt.GATT_FAILURE,
                0,
                null
            )
            if (valid) {
                synchronized(this@BlePeripheral) {
                    runCatching {
                        val data = fragments.getOrPut(device) { BleFragments() }.accept(value) ?: return
                        val objectValue = JSONObject(String(data, Charsets.UTF_8))
                        val session = sessions[device] ?: BleSecureSession(requireNotNull(BleTrust.key(context))).also { sessions[device] = it }
                        when {
                            objectValue.optString("type") == "hello" -> enqueue(device, session.hello(objectValue).toString().toByteArray())
                            objectValue.optString("type") == "finish" -> {
                                session.finish(objectValue)
                                enqueue(device, session.seal(JSONObject().put("type", "ready")))
                            }
                            else -> {
                                val command = session.open(objectValue)
                                when (command.optString("type")) {
                                    "get" -> publish(device, command.optLong("request"))
                                    "state" -> onCommand(if (command.optBoolean("connected")) "CONNECTED" else "DISCONNECTED")
                                    "subscribe" -> {
                                        val snapshot = PhoneNotifications.live?.snapshot()
                                        snapshot?.forEach { enqueue(device, session.seal(it)) }
                                    }
                                    "dismiss" -> {
                                        val success = PhoneNotifications.live?.dismiss(command) == true
                                        enqueue(device, session.seal(JSONObject().put("type", "dismissResult")
                                            .put("request", command.optString("request")).put("success", success)))
                                    }
                                    "action" -> {
                                        val success = PhoneNotifications.live?.perform(command) == true
                                        enqueue(device, session.seal(JSONObject().put("type", "actionResult").put("request", command.optString("request")).put("success", success)))
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
            val value = if (subscribed[device] == true) BluetoothGattDescriptor.ENABLE_INDICATION_VALUE
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
                 value.contentEquals(BluetoothGattDescriptor.DISABLE_NOTIFICATION_VALUE))
            if (valid) {
                synchronized(this@BlePeripheral) {
                    // Core Bluetooth can resubscribe without disconnecting the
                    // shared physical link. Its next hello belongs to a new
                    // authenticated session, not the old session's nonce state.
                    revokeSession(device)
                    if (value.contentEquals(BluetoothGattDescriptor.ENABLE_INDICATION_VALUE)) subscribed[device] = true
                }
            }
            if (responseNeeded) server?.sendResponse(
                device, requestId, if (valid) BluetoothGatt.GATT_SUCCESS else BluetoothGatt.GATT_FAILURE, 0, null
            )
        }
    }
}
