package app.droidmirror.bluetooth.bridge

import app.droidmirror.bluetooth.CameraVideoPacket
import android.os.SystemClock
import android.content.Context
import android.net.LocalServerSocket
import android.net.LocalSocket
import org.json.JSONObject
import java.io.DataInputStream
import java.io.DataOutputStream
import java.security.SecureRandom
import java.util.concurrent.LinkedBlockingQueue
import java.util.concurrent.atomic.AtomicInteger

/** QUIC authenticates the paired camera identity; BLE supplies a fresh session capability. */
class CameraIrohChannel(context: Context, key: ByteArray, private val session: String,
    private val valid: () -> Boolean) : AutoCloseable {
    private val token = ByteArray(32).also { SecureRandom().nextBytes(it) }.joinToString("") { "%02x".format(it.toInt() and 255) }
    private val listener = LocalServerSocket("droidmirror_camera")
    private val endpoint = try { app.droidmirror.bluetooth.PeerCameraEndpoint(context, key.copyOf()) } catch (error: Throwable) { listener.close(); throw error }
    private val queue = LinkedBlockingQueue<ByteArray>(4)
    private val queued = AtomicInteger()
    @Volatile var closed = false
        private set
    private val opened = SystemClock.elapsedRealtime()
    @Volatile private var lastProgress = opened
    @Volatile var ready = false
        private set
    @Volatile private var socket: LocalSocket? = null
    private var sequence = 0L
    val offer = JSONObject().put("type", "cameraIrohOffer").put("session", session).put("videoVersion", 2).put("token", token).put("addresses", endpoint.addresses(context))
    private val writer = Thread({
        try {
            val candidate = listener.accept(); socket = candidate
            candidate.soTimeout = 5000
            val input = DataInputStream(candidate.inputStream)
            val length = input.readInt(); require(length in 1..1024)
            val bytes = ByteArray(length); input.readFully(bytes)
            val hello = JSONObject(String(bytes, Charsets.UTF_8))
            require(hello.optString("token") == token && hello.optString("session") == session && hello.optInt("version") == 2 && valid())
            val output = DataOutputStream(candidate.outputStream)
            fun write(data: ByteArray) { output.writeInt(data.size); output.write(data); output.flush() }
            write(JSONObject().put("success", true).put("seq", 0).put("version", 2).toString().toByteArray())
            lastProgress = SystemClock.elapsedRealtime()
            ready = true
            listener.close()
            while (!closed && valid()) {
                val data = queue.poll(500, java.util.concurrent.TimeUnit.MILLISECONDS) ?: continue
                require(valid())
                write(data); queued.addAndGet(-data.size); lastProgress = SystemClock.elapsedRealtime()
            }
        } catch (_: Exception) { /* BLE fallback stays authenticated and independent. */ }
        finally { close() }
    }, "camera-iroh-writer").apply { isDaemon = true; start() }
    fun stalled(now: Long): Boolean = if (!ready) now - opened > 10000
        else queued.get() > 0 && now - lastProgress > 1500
    @Synchronized fun sendFrame(epoch: Int, ptsUs: Long, keyframe: Boolean, payload: ByteArray): Boolean {
        if (!ready || closed || !valid()) return false
        val bytes = CameraVideoPacket.encode(epoch, sequence + 1, ptsUs, keyframe, payload)
        if (queued.get() + bytes.size > 1024 * 1024) return false
        queued.addAndGet(bytes.size)
        if (!queue.offer(bytes)) { queued.addAndGet(-bytes.size); return false }
        sequence++
        return true
    }
    override fun close() {
        closed = true; ready = false
        runCatching { socket?.close() }; runCatching { listener.close() }; runCatching { endpoint.close() }
        queue.clear()
    }
}
