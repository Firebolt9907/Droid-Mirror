package app.droidmirror.bluetooth.bridge

import android.annotation.SuppressLint
import android.bluetooth.BluetoothDevice
import android.bluetooth.BluetoothGatt
import android.bluetooth.BluetoothGattCallback
import android.bluetooth.BluetoothProfile
import android.content.Context
import android.os.Handler
import android.util.Log
import org.json.JSONObject

/** Main-thread owner of a parameter request on the existing authenticated LE link.
 * No discovery, characteristics, clipboard payloads or periodic idle work use this client.
 */
@SuppressLint("MissingPermission")
internal class ClipboardBulkPriority(private val context: Context, private val device: BluetoothDevice,
    private val main: Handler, private val valid: () -> Boolean) : AutoCloseable {
    private val sending = mutableMapOf<String, Int>()
    private val receiving = mutableMapOf<String, Int>()
    private var client: BluetoothGatt? = null
    private var attempted = false
    private var connected = false
    private var closed = false
    private var requestedHigh = false
    private val callback = object : BluetoothGattCallback() {
        override fun onConnectionStateChange(gatt: BluetoothGatt, status: Int, newState: Int) {
            main.post {
                if (closed || !valid() || client !== gatt) { gatt.close(); return@post }
                if (status == BluetoothGatt.GATT_SUCCESS && newState == BluetoothProfile.STATE_CONNECTED) {
                    connected = true; update()
                } else if (newState == BluetoothProfile.STATE_DISCONNECTED || status != BluetoothGatt.GATT_SUCCESS) {
                    Log.i("DroidMirrorClipboard", "Bulk parameter client unavailable status=$status")
                    client = null; connected = false; requestedHigh = false; gatt.close()
                }
            }
        }
    }
    fun event(event: JSONObject, outbound: Boolean) {
        if (closed || !valid()) return
        val id = event.optString("id")
        when (event.optString("type")) {
            "clipboardFileBegin" -> (if (outbound) sending else receiving)[id] = event.optInt("size", -1)
            "clipboardFileAck" -> {
                val transfers = if (outbound) receiving else sending
                if (transfers[id] == event.optInt("offset", -2)) transfers.remove(id)
            }
            "clipboardFileCancel" -> { sending.remove(id); receiving.remove(id) }
        }
        update()
        // Active-only watchdog; a stalled transfer cannot leave high priority set.
        if (sending.isNotEmpty() || receiving.isNotEmpty()) {
            main.removeCallbacks(idle)
            main.postDelayed(idle, 60000)
        } else { main.removeCallbacks(idle) }
    }
    private val idle = Runnable { sending.clear(); receiving.clear(); update() }
    private fun update() {
        if (closed || !valid()) return
        val high = sending.isNotEmpty() || receiving.isNotEmpty()
        if (high && client == null && !attempted) {
            attempted = true
            // GATT client/server roles are independent of the link's central/peripheral
            // roles. This attaches a client to the already connected authenticated peer.
            client = runCatching { device.connectGatt(context, false, callback, BluetoothDevice.TRANSPORT_LE) }
                .onFailure { Log.w("DroidMirrorClipboard", "Bulk parameter client unavailable", it) }.getOrNull()
            val pending = client
            main.postDelayed({
                if (!closed && client === pending && !connected) { client = null; pending?.close() }
            }, 10000)
        }
        if (connected && high != requestedHigh) {
            val accepted = runCatching { client?.requestConnectionPriority(if (high) BluetoothGatt.CONNECTION_PRIORITY_HIGH else BluetoothGatt.CONNECTION_PRIORITY_BALANCED) == true }.getOrDefault(false)
            Log.i("DroidMirrorClipboard", "Bulk connection priority high=$high requested=$accepted")
            if (accepted) requestedHigh = high
        }
    }
    override fun close() {
        if (closed) return
        closed = true; main.removeCallbacks(idle)
        if (requestedHigh) runCatching { client?.requestConnectionPriority(BluetoothGatt.CONNECTION_PRIORITY_BALANCED) }
        // Unregister only; disconnect() would disturb the shared authenticated link.
        client?.close(); client = null; sending.clear(); receiving.clear()
    }
}
