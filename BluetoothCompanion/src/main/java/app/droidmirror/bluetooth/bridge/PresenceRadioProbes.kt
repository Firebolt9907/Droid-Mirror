package app.droidmirror.bluetooth.bridge

import android.Manifest
import android.bluetooth.BluetoothManager
import android.bluetooth.le.*
import android.content.Context
import android.content.pm.PackageManager
import android.location.LocationManager
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.os.ParcelUuid
import android.provider.Settings
import app.droidmirror.bluetooth.PresenceProtocol

/** Passive beacon only. No GATT connection, Classic socket, or bonded-device enumeration. */
@Suppress("MissingPermission", "DEPRECATION")
class PresenceRadioProbes(private val context: Context, private val result: (Boolean?, String) -> Unit) : AutoCloseable {
    private val handler = Handler(Looper.getMainLooper())
    private var scan: ScanCallback? = null
    private var scanner: BluetoothLeScanner? = null
    private var generation = 0
    private var running = false
    private var closed = false
    private fun mirroring() = app.droidmirror.bluetooth.CaptureService.mirrorOwnsRadio() ||
        app.droidmirror.bluetooth.WearSessionAccess.token().isNotEmpty()
    fun run() {
        if (closed || running) return
        // Retain the existing radio-ownership guard; an interrupted scan is never a miss.
        if (mirroring()) { result(null, "Beacon scan deferred during active mirroring"); return }
        val key = BleTrust.key(context) ?: return
        if (Build.VERSION.SDK_INT >= 31 && context.checkSelfPermission(Manifest.permission.BLUETOOTH_SCAN) != PackageManager.PERMISSION_GRANTED) {
            result(null, "Bluetooth SCAN permission required; open detection settings"); return
        }
        val locationReady = Build.VERSION.SDK_INT >= 31 ||
            (context.checkSelfPermission(Manifest.permission.ACCESS_FINE_LOCATION) == PackageManager.PERMISSION_GRANTED &&
                (if (Build.VERSION.SDK_INT >= 28) context.getSystemService(LocationManager::class.java).isLocationEnabled
                 else Settings.Secure.getInt(context.contentResolver, Settings.Secure.LOCATION_MODE, 0) != 0))
        if (!locationReady) { result(null, "BLE scanning needs Location permission and Location enabled on Android 11 or earlier"); return }
        val radio = runCatching { context.getSystemService(BluetoothManager::class.java).adapter?.bluetoothLeScanner }.getOrNull()
        if (radio == null) { result(null, "BLE scanner unavailable; check Bluetooth and permissions"); return }
        running = true
        val token = ++generation
        var seen = false
        fun valid() = !closed && running && generation == token
        fun finish(present: Boolean?, detail: String) {
            if (!valid()) return
            cancel()
            result(present, detail)
        }
        val callback = object : ScanCallback() {
            override fun onScanResult(callbackType: Int, value: ScanResult) { handler.post {
                if (!valid()) return@post
                if (mirroring()) finish(null, "Beacon scan interrupted by active mirroring") else seen = true
            } }
            override fun onScanFailed(errorCode: Int) { handler.post { finish(null, "BLE scan failed ($errorCode)") } }
        }
        scanner = radio; scan = callback
        try {
            radio.startScan(listOf(ScanFilter.Builder().setServiceUuid(ParcelUuid(PresenceProtocol.beacon(key))).build()),
                ScanSettings.Builder().setScanMode(ScanSettings.SCAN_MODE_LOW_LATENCY).build(), callback)
        } catch (error: Exception) { finish(null, "BLE scan unavailable: ${error.javaClass.simpleName}"); return }
        handler.postDelayed({
            if (mirroring()) finish(null, "Beacon scan interrupted by active mirroring")
            else finish(seen, if (seen) "Paired Mac beacon observed" else "No paired Mac beacon in 20s scan")
        }, 20_000)
    }
    fun cancel() {
        generation++; running = false
        handler.removeCallbacksAndMessages(null)
        runCatching { scan?.let { scanner?.stopScan(it) } }
        scan = null; scanner = null
    }
    override fun close() { closed = true; cancel() }
}
