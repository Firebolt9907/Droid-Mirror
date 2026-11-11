package app.droidmirror.bluetooth.bridge

import android.content.Context
import android.os.Handler
import android.os.Looper
import android.os.PowerManager
import android.os.SystemClock
import org.json.JSONObject
import java.io.ByteArrayOutputStream
import java.security.SecureRandom
import java.util.concurrent.ArrayBlockingQueue
import java.util.concurrent.ThreadPoolExecutor
import java.util.concurrent.TimeUnit

/** Explicit synthetic test. No ClipboardManager, clipboard bridge or Shizuku access. */
class BleBulkTest(private val context: Context, private val config: JSONObject, private val peer: android.bluetooth.BluetoothDevice,
    private val valid: () -> Boolean, private val control: (JSONObject) -> Unit) : AutoCloseable {
    private val main = Handler(Looper.getMainLooper())
    val id: String = config.getString("id")
    private val size = config.getInt("bytes")
    private val window = config.getInt("window")
    private val transport = config.getString("transport")
    private val key = ClipboardBulkCodec.benchmarkKey(requireNotNull(BleTrust.key(context)))
    private val token = ByteArray(32).also { SecureRandom().nextBytes(it) }.joinToString("") { "%02x".format(it.toInt() and 255) }
    private val worker = ThreadPoolExecutor(1, 1, 0, TimeUnit.SECONDS, ArrayBlockingQueue<Runnable>(128))
    private var codec = ClipboardBulkCodec(key, token)
    private val buffered = ByteArrayOutputStream()
    private var ip: ClipboardIrohChannel? = null
    private var channel: ClipboardBulkChannel? = null
    private var hello = false
    private var priority: ClipboardBulkPriority? = null
    private var started = false
    @Volatile private var closed = false
    private var complete = false
    private var count = 0
    private var chunks = 0
    private var beganAt = 0L
    private var lockedAtStart = false
    private val payload = BleBulkTestPayload(size)
    private val wake = context.getSystemService(PowerManager::class.java).newWakeLock(PowerManager.PARTIAL_WAKE_LOCK, "DroidMirror:synthetic-ble-test")
    private fun locked() = context.getSystemService(android.app.KeyguardManager::class.java).isDeviceLocked
    init {
        require(id.matches(Regex("[A-Fa-f0-9-]{36}")) && size in 1..4_000_000 && window in setOf(0, 1, 8, 32))
        require(transport in setOf("l2cap", "gatt", "iroh"))
        wake.acquire(180_000)
        main.postDelayed({ fail("deadline") }, 180_000)
    }
    fun start() {
        if (!valid() || closed) { close(); return }
        val offer = JSONObject().put("type", "bulkTestOffer").put("id", id).put("transport", transport)
        if (transport == "iroh") {
            ip = ClipboardIrohChannel(context, key, valid, { receive(it) }, { fail("iroh failed") }, receiveOnReader = true)
            val fresh = requireNotNull(ip)
            fun publish(attempt: Int) {
                if (closed || !valid()) return
                val bulk = fresh.offer
                if (bulk.getJSONArray("addresses").length() > 0 || attempt >= 15) {
                    offer.put("token", bulk.getString("token")).put("addresses", bulk.getJSONArray("addresses")); control(offer)
                } else main.postDelayed({ publish(attempt + 1) }, 100)
            }
            publish(0); return
        } else if (transport == "l2cap") {
            channel = ClipboardBulkChannel(context, key, valid,
                { event -> receive(event) }, { fail("channel failed") }, receiveOnReader = true)
            val bulk = requireNotNull(channel).offer
            offer.put("psm", bulk.getInt("psm")).put("token", bulk.getString("token"))
        } else { priority = ClipboardBulkPriority(context, peer, main, valid); offer.put("token", token) }
        control(offer)
    }
    private fun send(event: JSONObject) {
        if (closed || !valid()) return
        if (transport == "iroh") {
            if (ip?.send(event) != true) fail("output queue full")
        } else if (transport == "l2cap") {
            if (channel?.send(event) != true) fail("output queue full")
        } else { main.post { if (!closed) priority?.event(event, true) }; control(JSONObject().put("type", "bulkTestEvent").put("id", id).put("event", event)) }
    }
    fun fragment(bytes: ByteArray) {
        if (transport != "gatt" || closed || !valid() || bytes.size !in 1..517) return
        try { worker.execute { try {
            if (closed || !valid()) return@execute
            require(buffered.size() + bytes.size <= ClipboardBulkCodec.MAXIMUM + 521)
            buffered.write(bytes)
            var data = buffered.toByteArray(); var offset = 0
            while (data.size - offset >= 4) {
                val n = java.nio.ByteBuffer.wrap(data, offset, 4).int
                require(n in 25..ClipboardBulkCodec.MAXIMUM)
                if (data.size - offset < n + 4) break
                receive(codec.open(data.copyOfRange(offset + 4, offset + 4 + n)))
                offset += n + 4
                if (closed) return@execute
            }
            buffered.reset(); buffered.write(data, offset, data.size - offset)
        } catch (_: Exception) { fail("invalid record") } } }
        catch (_: java.util.concurrent.RejectedExecutionException) { fail("input queue full") }
    }
    @Synchronized private fun receive(event: JSONObject) {
        if (closed || !valid() || complete) return
        if (transport == "gatt") main.post { if (!closed) priority?.event(event, false) }
        when (event.getString("type")) {
            "clipboardBulkHello" -> {
                require(transport == "gatt" && !hello && !started); hello = true
                send(JSONObject().put("type", "clipboardBulkReady"))
            }
            "clipboardFileBegin" -> {
                require((transport != "gatt" || hello) && !started && event.getString("id") == id && event.getInt("size") == size)
                started = true; beganAt = SystemClock.elapsedRealtime(); lockedAtStart = locked()
                send(JSONObject().put("type", "clipboardFileAck").put("id", id).put("offset", 0).put("window", window))
            }
            "clipboardFileChunk" -> {
                require(started && event.getString("id") == id && event.getInt("offset") == count)
                val data = BleTrust.unb64(event.getString("data").replace('-', '+').replace('_', '/'))
                payload.append(count, data); count = payload.count; chunks++
                if (count == size) {
                    complete = true
                    val elapsed = maxOf(1L, SystemClock.elapsedRealtime() - beganAt)
                    val result = JSONObject().put("type", "clipboardFileAck").put("id", id).put("offset", count)
                        .put("elapsedMs", elapsed).put("sha256", payload.sha256())
                        .put("lockedStart", lockedAtStart).put("lockedEnd", locked())
                    send(result)
                    control(JSONObject().put("type", "bulkTestEvent").put("id", id).put("event", result))
                    android.util.Log.i("DroidMirrorBulkTest", "Complete transport=$transport window=$window bytes=$count elapsedMs=$elapsed lockedStart=$lockedAtStart lockedEnd=${locked()}")
                    main.postDelayed({ close() }, 2000)
                } else if (window > 0 && chunks % window == 0) {
                    send(JSONObject().put("type", "clipboardFileAck").put("id", id).put("offset", count))
                }
            }
            "clipboardFileCancel" -> close()
            else -> error("unexpected synthetic event")
        }
    }
    private fun fail(reason: String) {
        if (closed) return
        if (complete) { close(); return }
        android.util.Log.w("DroidMirrorBulkTest", "Failed reason=$reason bytes=$count")
        control(JSONObject().put("type", "bulkTestError").put("id", id).put("reason", reason))
        close()
    }
    @Synchronized override fun close() {
        if (closed) return
        closed = true; main.removeCallbacksAndMessages(null)
        main.post { priority?.close(); priority = null }
        ip?.close(); ip = null
        channel?.close(); channel = null; worker.shutdownNow()
        if (wake.isHeld) wake.release()
        android.util.Log.i("DroidMirrorBulkTest", "Closed id=$id bytes=$count")
    }
}
