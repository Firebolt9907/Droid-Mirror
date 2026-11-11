package app.droidmirror.bluetooth.bridge

import android.content.Context
import android.os.Handler
import android.os.Looper
import org.json.JSONObject
import java.io.DataInputStream
import java.io.DataOutputStream
import java.security.SecureRandom
import java.util.concurrent.LinkedBlockingQueue
import java.util.concurrent.atomic.AtomicInteger

/** Direct-IP Iroh stream, authenticated by a fresh BLE-delivered capability. */
class ClipboardIrohChannel(private val context: Context, key: ByteArray, private val valid: () -> Boolean,
    private val receive: (JSONObject) -> Unit, private val failed: () -> Unit, private val receiveOnReader: Boolean = false) : AutoCloseable {
    private val main = Handler(Looper.getMainLooper())
    private val token = ByteArray(32).also { SecureRandom().nextBytes(it) }.joinToString("") { "%02x".format(it.toInt() and 255) }
    // The native endpoint pins its paired clipboard identity; records also prove the BLE capability.
    private val listener = android.net.LocalServerSocket("droidmirror_clipboard")
    private val endpoint = try { app.droidmirror.bluetooth.PeerClipboardEndpoint(context, key.copyOf()) } catch (error: Throwable) { listener.close(); throw error }
    private val master = javax.crypto.Mac.getInstance("HmacSHA256").run { init(javax.crypto.spec.SecretKeySpec(key, "HmacSHA256")); doFinal("DroidMirror clipboard Iroh v1".toByteArray()) }
    private val inbound = java.util.concurrent.Semaphore(128)
    private val queued = AtomicInteger()
    private data class Message(val value: JSONObject, val cost: Int)
    private val outgoing = LinkedBlockingQueue<Message>()
    @Volatile private var closed = false
    @Volatile private var ready = false
    @Volatile private var socket: android.net.LocalSocket? = null
    private var writer: Thread? = null

    private val reader = Thread({ readLoop() }, "clipboard-iroh-reader")
    private val openingTimeout = Runnable { if (!ready) fail() }
    val connected: Boolean get() = ready
    val offer: JSONObject get() = JSONObject().put("type", "clipboardIrohOffer").put("token", token).put("addresses", endpoint.addresses(context))
    init {
        require(key.size == 32)
        main.postDelayed(openingTimeout, 10000)
        reader.start()
    }
    fun send(event: JSONObject): Boolean {
        if (closed || !valid() || event.optString("type") !in ClipboardBulkCodec.FILES) return false
        val copy = JSONObject(event.toString())
        val cost = copy.toString().toByteArray(Charsets.UTF_8).size + 64
        val total = queued.addAndGet(cost)
        if (total > 8_000_000 || closed) { queued.addAndGet(-cost); return false }
        outgoing.add(Message(copy, cost))
        return true
    }
    private fun readLoop() {
        try {
            var accepted: android.net.LocalSocket? = null
            var codec: ClipboardBulkCodec? = null
            while (!closed && valid() && accepted == null) {
                val candidate = listener.accept(); socket = candidate
                try {
                    val fresh = ClipboardBulkCodec(master, token)
                    val input = DataInputStream(candidate.inputStream)
                    require(fresh.open(readFrame(input)).optString("type") == "clipboardBulkHello" && valid())
                    val output = DataOutputStream(candidate.outputStream)
                    writeFrame(output, fresh.seal(JSONObject().put("type", "clipboardBulkReady")))
                    accepted = candidate; codec = fresh
                } catch (error: Exception) { android.util.Log.w("DroidMirrorClipboard", "Iroh handshake rejected", error); candidate.close(); socket = null }
            }
            val connection = requireNotNull(accepted); val cipher = requireNotNull(codec)
            android.util.Log.i("DroidMirrorClipboard", "Clipboard Iroh authenticated")
            ready = true; main.removeCallbacks(openingTimeout); listener.close()

            writer = Thread({
                try {
                    val output = DataOutputStream(connection.outputStream)
                    while (!closed) {
                        val message = outgoing.take()
                        require(valid())

                        val watchdog = Runnable { fail() }
                        main.postDelayed(watchdog, 60000)
                        try { writeFrame(output, cipher.seal(message.value)) }
                        finally { main.removeCallbacks(watchdog) }
                        queued.addAndGet(-message.cost)
                    }
                } catch (error: Exception) { if (!closed) android.util.Log.w("DroidMirrorClipboard", "Iroh I/O failed", error); fail() }
            }, "clipboard-iroh-writer").also { it.start() }
            val input = DataInputStream(connection.inputStream)
            while (!closed) {
                val record = readFrame(input)
                require(valid())
                val event = cipher.open(record)
                require(event.optString("type") in ClipboardBulkCodec.FILES)
                if (receiveOnReader) {

                    if (!closed && valid()) receive(event)
                } else {
                    inbound.acquire()
                    main.post { try { if (!closed && valid()) receive(event) } finally { inbound.release() } }
                }
            }
        } catch (error: Exception) { if (!closed) android.util.Log.w("DroidMirrorClipboard", "Iroh I/O failed", error); fail() }
    }
    private fun readFrame(input: DataInputStream): ByteArray {
        val size = input.readInt(); require(size in 25..ClipboardBulkCodec.MAXIMUM)
        return ByteArray(size).also { input.readFully(it) }
    }
    private fun writeFrame(output: DataOutputStream, bytes: ByteArray) {
        // Write one bounded, length-prefixed encrypted record.
        val frame = java.nio.ByteBuffer.allocate(4 + bytes.size).putInt(bytes.size).put(bytes).array()
        output.write(frame); output.flush()
    }
    private fun fail() {
        synchronized(this) { if (closed) return; close() }
        main.post { failed() }
    }
    @Synchronized override fun close() {
        if (closed) return
        closed = true
        main.removeCallbacksAndMessages(null)

        runCatching { socket?.close() }; runCatching { listener.close() }
        reader.interrupt(); writer?.interrupt(); outgoing.clear()
        Thread({ endpoint.close() }, "clipboard-iroh-close").start()
    }
}
