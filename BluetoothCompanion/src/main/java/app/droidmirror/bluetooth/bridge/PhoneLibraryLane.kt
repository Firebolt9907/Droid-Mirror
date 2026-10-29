package app.droidmirror.bluetooth.bridge

import android.content.Context
import android.net.LocalServerSocket
import android.net.LocalSocket
import android.os.SystemClock
import app.droidmirror.bluetooth.PeerLibraryEndpoint
import org.json.JSONObject
import java.io.DataInputStream
import java.io.DataOutputStream
import java.security.MessageDigest
import java.util.concurrent.CompletableFuture
import java.util.concurrent.TimeUnit

/** Short-lived read-only lane, bootstrapped by the current authenticated BLE session. */
class PhoneLibraryLane(context: Context, key: ByteArray, private val token: String,
    private val authorized: () -> Boolean,
    private val read: (JSONObject, (JSONObject) -> Unit) -> Unit) : AutoCloseable {
    private val listener = LocalServerSocket("droidmirror_app_library")
    private var endpoint: PeerLibraryEndpoint? = null
    @Volatile private var socket: LocalSocket? = null
    @Volatile private var closed = false
    private val started = SystemClock.elapsedRealtime()
    @Volatile private var touched = started
    init {
        try { endpoint = PeerLibraryEndpoint(context, key) }
        catch (failure: Throwable) { listener.close(); throw failure }
        Thread({ serve() }, "AppLibraryIroh").apply { isDaemon = true; start() }
        Thread({
            while (!closed) {
                Thread.sleep(1000)
                if (!authorized() || SystemClock.elapsedRealtime() - touched > 15000 ||
                    SystemClock.elapsedRealtime() - started > 300000) close()
            }
        }, "AppLibraryLease").apply { isDaemon = true; start() }
    }
    fun addresses(context: Context) = endpoint?.addresses(context) ?: org.json.JSONArray()
    private fun serve() {
        try {
            // Invalid local candidates cannot consume the one-use session capability.
            var accepted = false
            while (!closed && !accepted) {
                val candidate = listener.accept(); socket = candidate
                try {
                    candidate.soTimeout = 5000
                    val input = DataInputStream(candidate.inputStream)
                    val output = DataOutputStream(candidate.outputStream)
                    val hello = frame(input)
                    require(authorized() && MessageDigest.isEqual(hello.optString("token").toByteArray(), token.toByteArray()))
                    accepted = true
                    write(output, JSONObject().put("success", true).put("seq", 0))
                    candidate.soTimeout = 15000
                    var sequence = 1L
                    while (!closed && authorized() && sequence <= 20000) {
                        val command = frame(input)
                        require(command.getLong("seq") == sequence)
                        require(command.optString("type") in setOf("appCatalogRequest", "appIconRequest"))
                        touched = SystemClock.elapsedRealtime()
                        val response = CompletableFuture<JSONObject>()
                        read(command) { response.complete(it) }
                        val result = response.get(10, TimeUnit.SECONDS)
                        require(!closed && authorized())
                        write(output, result.put("seq", sequence++))
                        touched = SystemClock.elapsedRealtime()
                    }
                } catch (_: Exception) { }
                finally { candidate.close(); socket = null }
            }
        } catch (_: Exception) { }
        finally { close() }
    }
    private fun frame(input: DataInputStream): JSONObject {
        val size = input.readInt(); require(size in 1..65536)
        val bytes = ByteArray(size); input.readFully(bytes)
        return JSONObject(String(bytes, Charsets.UTF_8))
    }
    private fun write(output: DataOutputStream, value: JSONObject) {
        val bytes = value.toString().toByteArray(Charsets.UTF_8); require(bytes.size <= 98304)
        output.writeInt(bytes.size); output.write(bytes); output.flush()
    }
    @Synchronized override fun close() {
        if (closed) return
        closed = true
        runCatching { socket?.close() }; runCatching { listener.close() }
        endpoint?.close(); endpoint = null
    }
}
