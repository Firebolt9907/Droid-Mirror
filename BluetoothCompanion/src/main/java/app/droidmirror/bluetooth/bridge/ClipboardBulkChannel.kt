package app.droidmirror.bluetooth.bridge

import android.annotation.SuppressLint
import android.bluetooth.BluetoothManager
import android.bluetooth.BluetoothServerSocket
import android.bluetooth.BluetoothSocket
import android.content.Context
import android.os.Handler
import android.os.Looper
import org.json.JSONObject
import java.io.DataInputStream
import java.io.DataOutputStream
import java.security.SecureRandom
import java.util.concurrent.LinkedBlockingQueue
import java.util.concurrent.atomic.AtomicInteger

/** One lazily created LE CoC for one authenticated clipboard subscription. */
@SuppressLint("MissingPermission")
class ClipboardBulkChannel(private val context: Context, key: ByteArray, private val valid: () -> Boolean,
    private val receive: (JSONObject) -> Unit, private val failed: () -> Unit, private val receiveOnReader: Boolean = false) : AutoCloseable {
    private val main = Handler(Looper.getMainLooper())
    private val token = ByteArray(32).also { SecureRandom().nextBytes(it) }.joinToString("") { "%02x".format(it.toInt() and 255) }
    // Existing app pairing authenticates/encrypts every record; no new OS bonding UI is required.
    private val listener: BluetoothServerSocket = context.getSystemService(BluetoothManager::class.java).adapter.listenUsingInsecureL2capChannel()
    private val master = key.copyOf()
    private val queued = AtomicInteger()
    private data class Message(val value: JSONObject, val cost: Int)
    private val outgoing = LinkedBlockingQueue<Message>()
    @Volatile private var closed = false
    @Volatile private var ready = false
    @Volatile private var socket: BluetoothSocket? = null
    private var writer: Thread? = null
    private var priority: ClipboardBulkPriority? = null
    private val reader = Thread({ readLoop() }, "clipboard-l2cap-reader")
    private val openingTimeout = Runnable { if (!ready) fail() }
    val connected: Boolean get() = ready
    val offer: JSONObject get() = JSONObject().put("type", "clipboardBulkOffer").put("psm", listener.psm).put("token", token)
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
        if (total > 262144 || closed) { queued.addAndGet(-cost); return false }
        outgoing.add(Message(copy, cost))
        return true
    }
    private fun readLoop() {
        try {
            var accepted: BluetoothSocket? = null
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
                } catch (error: Exception) { android.util.Log.w("DroidMirrorClipboard", "L2CAP handshake rejected", error); candidate.close(); socket = null }
            }
            val connection = requireNotNull(accepted); val cipher = requireNotNull(codec)
            android.util.Log.i("DroidMirrorClipboard", "Clipboard L2CAP authenticated rxPacket=${connection.maxReceivePacketSize} txPacket=${connection.maxTransmitPacketSize}")
            ready = true; main.removeCallbacks(openingTimeout); listener.close()
            main.post { if (!closed && valid()) priority = ClipboardBulkPriority(context, connection.remoteDevice, main, valid) }
            writer = Thread({
                try {
                    val output = DataOutputStream(connection.outputStream)
                    while (!closed) {
                        val message = outgoing.take()
                        require(valid())
                        main.post { if (!closed) priority?.event(message.value, true) }
                        val watchdog = Runnable { fail() }
                        main.postDelayed(watchdog, 60000)
                        try { writeFrame(output, cipher.seal(message.value)) }
                        finally { main.removeCallbacks(watchdog) }
                        queued.addAndGet(-message.cost)
                    }
                } catch (error: Exception) { if (!closed) android.util.Log.w("DroidMirrorClipboard", "L2CAP I/O failed", error); fail() }
            }, "clipboard-l2cap-writer").also { it.start() }
            val input = DataInputStream(connection.inputStream)
            while (!closed) {
                val record = readFrame(input)
                require(valid())
                val event = cipher.open(record)
                require(event.optString("type") in ClipboardBulkCodec.FILES)
                if (receiveOnReader) {
                    main.post { if (!closed && valid()) priority?.event(event, false) }
                    if (!closed && valid()) receive(event)
                } else main.post { if (!closed && valid()) { priority?.event(event, false); receive(event) } }
            }
        } catch (error: Exception) { if (!closed) android.util.Log.w("DroidMirrorClipboard", "L2CAP I/O failed", error); fail() }
    }
    private fun readFrame(input: DataInputStream): ByteArray {
        val size = input.readInt(); require(size in 25..ClipboardBulkCodec.MAXIMUM)
        return ByteArray(size).also { input.readFully(it) }
    }
    private fun writeFrame(output: DataOutputStream, bytes: ByteArray) {
        // One socket write per record: a separate length write becomes a tiny LE CoC SDU.
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
        main.post { priority?.close(); priority = null }
        runCatching { socket?.close() }; runCatching { listener.close() }
        reader.interrupt(); writer?.interrupt(); outgoing.clear()
    }
}
