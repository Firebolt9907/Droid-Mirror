package app.droidmirror.bluetooth.bridge

import android.Manifest
import android.bluetooth.*
import android.bluetooth.le.*
import android.content.Context
import android.content.pm.PackageManager
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.os.ParcelUuid
import android.location.LocationManager
import android.provider.Settings
import app.droidmirror.bluetooth.PresenceProtocol
import java.security.MessageDigest
import java.security.SecureRandom
import java.util.UUID
import java.util.concurrent.Executors

/** One bounded radio round. Results: true=present, false=miss, null=not measurable. */
@Suppress("DEPRECATION", "MissingPermission")
class PresenceRadioProbes(private val context: Context, private val result: (Int, Boolean?, String) -> Unit) : AutoCloseable {
    companion object {
        val CHARACTERISTIC: UUID = UUID.fromString("7e57b102-9a6b-4c5d-8e7f-102030405060")
        fun uuid(key: ByteArray, label: String): UUID = PresenceProtocol.uuid(key, label)
    }
    private val handler = Handler(Looper.getMainLooper())
    private val worker = Executors.newSingleThreadExecutor()
    private val adapter get() = context.getSystemService(BluetoothManager::class.java).adapter
    @Volatile private var generation = 0
    @Volatile private var closed = false
    private var scan: ScanCallback? = null
    private var scanner: BluetoothLeScanner? = null
    private var gatt: BluetoothGatt? = null
    private var lastDevice: BluetoothDevice? = null
    @Volatile private var socket: BluetoothSocket? = null
    private var running = false
    private var roundKey: ByteArray? = null
    private fun mirroring() = app.droidmirror.bluetooth.CaptureService.mirrorOwnsRadio() ||
        app.droidmirror.bluetooth.WearSessionAccess.token().isNotEmpty()
    fun run() {
        if (closed || running) return
        // A reverse LE GATT probe makes macOS replace its active Classic GATT
        // bearer. That breaks the authenticated mirror input/return channel.
        // Mark measurements unavailable; never invent a successful presence proof.
        if (mirroring()) {
            for (i in 1..3) result(i, null, "Radio probe deferred during active mirroring")
            return
        }
        val key = BleTrust.key(context) ?: return
        if (roundKey != null && !MessageDigest.isEqual(roundKey, key)) lastDevice = null
        roundKey = key
        val canScan = Build.VERSION.SDK_INT < 31 || context.checkSelfPermission(Manifest.permission.BLUETOOTH_SCAN) == PackageManager.PERMISSION_GRANTED
        if (Build.VERSION.SDK_INT >= 31 && context.checkSelfPermission(Manifest.permission.BLUETOOTH_CONNECT) != PackageManager.PERMISSION_GRANTED) {
            for (i in 1..3) result(i, null, "Bluetooth CONNECT permission required; open detection settings")
            return
        }
        if (runCatching { adapter?.isEnabled }.getOrNull() != true) {
            for (i in 1..3) result(i, null, "Phone Bluetooth off")
            return
        }
        running = true
        val token = ++generation
        var beaconSeen = false
        var gattStarted = false
        var gattDone = false
        var classicDone = false
        val nonce = ByteArray(16).also { SecureRandom().nextBytes(it) }
        val service = uuid(key, "DroidMirror presence beacon v1")
        fun valid() = !closed && running && token == generation && !mirroring()
        fun gattResult(present: Boolean, detail: String) {
            if (!valid() || gattDone) return
            gattDone = true
            result(2, present, detail)
            releaseGatt()
        }
        fun connect(device: BluetoothDevice) {
            if (!valid() || gattStarted) return
            gattStarted = true
            val callback = object : BluetoothGattCallback() {
                private fun onMain(block: () -> Unit) { handler.post { if (valid() && !gattDone) block() } }
                override fun onConnectionStateChange(g: BluetoothGatt, status: Int, state: Int) = onMain {
                    if (status != BluetoothGatt.GATT_SUCCESS || state == BluetoothProfile.STATE_DISCONNECTED) gattResult(false, "GATT connection failed ($status)")
                    else if (state == BluetoothProfile.STATE_CONNECTED && !g.discoverServices()) gattResult(false, "GATT discovery rejected")
                }
                override fun onServicesDiscovered(g: BluetoothGatt, status: Int) = onMain {
                    val c = g.getService(service)?.getCharacteristic(CHARACTERISTIC)
                    if (status != BluetoothGatt.GATT_SUCCESS || c == null) gattResult(false, "Presence GATT service unavailable")
                    else {
                        val accepted = if (Build.VERSION.SDK_INT >= 33) g.writeCharacteristic(c, nonce, BluetoothGattCharacteristic.WRITE_TYPE_DEFAULT) == BluetoothStatusCodes.SUCCESS
                        else { c.writeType = BluetoothGattCharacteristic.WRITE_TYPE_DEFAULT; c.value = nonce; g.writeCharacteristic(c) }
                        if (!accepted) gattResult(false, "GATT challenge write rejected")
                    }
                }
                override fun onCharacteristicWrite(g: BluetoothGatt, c: BluetoothGattCharacteristic, status: Int) = onMain {
                    if (status != BluetoothGatt.GATT_SUCCESS || !g.readCharacteristic(c)) gattResult(false, "GATT challenge failed")
                }
                private fun proof(value: ByteArray, status: Int) = onMain {
                    val expected = PresenceProtocol.proof(key, "gatt", nonce)
                    val ok = status == BluetoothGatt.GATT_SUCCESS && MessageDigest.isEqual(expected, value)
                    gattResult(ok, if (ok) "Fresh authenticated GATT response" else "GATT proof missing/invalid")
                }
                override fun onCharacteristicRead(g: BluetoothGatt, c: BluetoothGattCharacteristic, value: ByteArray, status: Int) { proof(value, status) }
                override fun onCharacteristicRead(g: BluetoothGatt, c: BluetoothGattCharacteristic, status: Int) {
                    if (Build.VERSION.SDK_INT < 33) proof(c.value ?: byteArrayOf(), status)
                }
            }
            try { gatt = device.connectGatt(context, false, callback, BluetoothDevice.TRANSPORT_LE) }
            catch (_: Exception) { gattResult(false, "GATT connect unavailable") }
        }
        var scanStarted = false
        var scanUsable = false
        scan = object : ScanCallback() {
            override fun onScanResult(callbackType: Int, value: ScanResult) { handler.post {
                if (!valid()) return@post
                beaconSeen = true
                lastDevice = value.device
                connect(value.device)
            } }
            override fun onScanFailed(errorCode: Int) { handler.post {
                if (valid()) { scanUsable = false; result(1, null, "BLE scan failed ($errorCode)"); stopScan() }
            } }
        }
        val locationReady = Build.VERSION.SDK_INT >= 31 ||
            (context.checkSelfPermission(Manifest.permission.ACCESS_FINE_LOCATION) == PackageManager.PERMISSION_GRANTED &&
                (if (Build.VERSION.SDK_INT >= 28) context.getSystemService(LocationManager::class.java).isLocationEnabled
                 else Settings.Secure.getInt(context.contentResolver, Settings.Secure.LOCATION_MODE, 0) != 0))
        try {
            scanner = if (canScan && locationReady) adapter?.bluetoothLeScanner else null
            if (scanner != null) {
                scanner!!.startScan(listOf(ScanFilter.Builder().setServiceUuid(ParcelUuid(service)).build()),
                    ScanSettings.Builder().setScanMode(ScanSettings.SCAN_MODE_LOW_LATENCY).build(), scan)
                scanStarted = true
                scanUsable = true
            } else result(1, null, when {
                !canScan -> "Bluetooth SCAN permission required; open detection settings"
                !locationReady -> "BLE scan needs Location permission and Location enabled on Android 11 or earlier"
                else -> "BLE scanner unavailable"
            })
        } catch (_: Exception) { result(1, null, "BLE scan unavailable") }
        lastDevice?.let { connect(it) }
        // Only already bonded devices: never pair silently or infer presence from cached SDP.
        val bonded = runCatching { adapter?.bondedDevices?.toList().orEmpty() }.getOrDefault(emptyList())
        val prefs = context.getSharedPreferences("left-behind", Context.MODE_PRIVATE)
        val peerKey = "classic-presence-peer-${uuid(key, "DroidMirror presence classic v1")}"
        val known = prefs.getString(peerKey, null)
        // The app's explicitly paired Mac wins. Never rotate through unrelated computers.
        val configured = context.getSharedPreferences("ready", Context.MODE_PRIVATE).getString("peer", null)
        val target = configured?.takeIf { it.isNotBlank() } ?: known
        val device = bonded.firstOrNull { it.address.equals(target, ignoreCase = true) }
        val classicStage = java.util.concurrent.atomic.AtomicReference("opening RFCOMM socket / SDP")
        if (device == null) {
            classicDone = true; result(3, null, "Selected Mac is not bonded for Classic; select/pair your Mac in DroidMirror and Android Bluetooth settings")
        } else {
            worker.execute {
                var success = false
                var detail = "Classic connection/proof failed"
                var local: BluetoothSocket? = null
                try {
                    local = device.createInsecureRfcommSocketToServiceRecord(uuid(key, "DroidMirror presence classic v1"))
                    synchronized(this) {
                        if (token != generation || closed) { local.close(); return@execute }
                        socket = local
                    }
                    local.connect()
                    classicStage.set("writing challenge nonce")
                    val challenge = ByteArray(16).also { SecureRandom().nextBytes(it) }
                    local.outputStream.write(challenge); local.outputStream.flush()
                    classicStage.set("reading authenticated response")
                    val response = ByteArray(32)
                    var read = 0
                    while (read < response.size) {
                        val n = local.inputStream.read(response, read, response.size - read)
                        if (n < 0) throw java.io.EOFException()
                        read += n
                    }
                    success = MessageDigest.isEqual(response, PresenceProtocol.proof(key, "classic", challenge))
                    detail = if (success) "Fresh authenticated Classic RFCOMM response" else "Invalid Classic proof"
                } catch (error: Exception) {
                    detail = "Classic failed while ${classicStage.get()}: ${error.javaClass.simpleName}: ${error.message?.take(160).orEmpty()}"
                }
                finally { runCatching { local?.close() }; synchronized(this) { if (socket === local) socket = null } }
                handler.post {
                    if (valid() && !classicDone) {
                        classicDone = true
                        if (success) prefs.edit().putString(peerKey, device.address).apply()
                        result(3, success, "$detail (target: ${runCatching { device.name }.getOrNull() ?: device.address}; name is cached, not a presence result)")
                    }
                }
            }
        }
        handler.postDelayed({
            if (valid()) {
                stopScan()
                if (scanStarted && scanUsable) result(1, beaconSeen, if (beaconSeen) "Paired beacon observed (unauthenticated)" else "No paired beacon in 20s scan")
                if (!gattDone && !gattStarted && !scanUsable) {
                    gattDone = true; result(2, null, if (!canScan) "GATT discovery needs Bluetooth SCAN permission; Classic can still run" else "GATT discovery unavailable: BLE scan failed or unavailable")
                }
                if (!gattDone) gattResult(false, if (gattStarted) "GATT probe timed out" else "Mac GATT address not discovered")
                if (!classicDone) { classicDone = true; result(3, false, "Classic timed out while ${classicStage.get()} (selected Mac)") }
                synchronized(this) { runCatching { socket?.close() }; socket = null }
                running = false
            }
        }, 20_000)
    }
    private fun stopScan() { runCatching { scan?.let { scanner?.stopScan(it) } }; scan = null; scanner = null }
    private fun releaseGatt() {
        val connection = gatt; gatt = null
        runCatching { connection?.disconnect() }
        runCatching { connection?.close() }
    }
    fun cancel() {
        synchronized(this) { generation++; runCatching { socket?.close() }; socket = null }
        handler.removeCallbacksAndMessages(null)
        stopScan(); releaseGatt()
        running = false; lastDevice = null
    }
    override fun close() { closed = true; cancel(); worker.shutdownNow() }
}
