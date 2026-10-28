package app.droidmirror.bluetooth.bridge

import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.os.BatteryManager
import android.os.Handler
import android.os.Looper
import android.os.SystemClock
import app.droidmirror.bluetooth.WearSessionAccess
import app.droidmirror.wearprotocol.WearCommandPolicy
import app.droidmirror.wearprotocol.WearProtocol
import com.google.android.gms.wearable.Wearable
import org.json.JSONObject
import java.util.UUID

/** Main-thread owner; no extra foreground service, persistent command queue or pairing keys on watch. */
object WearPhoneBridge {
    private val main = Handler(Looper.getMainLooper())
    private var context: Context? = null
    private var mac: JSONObject? = null
    private var macAt = 0L
    private var macSend: ((JSONObject) -> Boolean)? = null
    private var macValid: (() -> Boolean)? = null
    private data class Lease(val node: String, val at: Long, val session: String, val mac: String)
    private val leases = linkedMapOf<String, Lease>()
    private val requests = linkedSetOf<String>()
    private val pending = mutableMapOf<String, String>()
    private val tick = object : Runnable {
        override fun run() {
            val ctx = context ?: return
            publish(ctx)
            if (BridgeRuntime.live != null || WearSessionAccess.token().isNotEmpty()) main.postDelayed(this, 10_000)
        }
    }
    @JvmStatic fun refresh(ctx: Context) {
        main.post { context = ctx.applicationContext; main.removeCallbacks(tick); main.post(tick) }
    }
    fun disconnected(ctx: Context) {
        main.post {
            mac = null; macSend = null; macValid = null
            pending.toMap().forEach { (request, node) -> result(ctx, node, request, "Mac disconnected") }
            pending.clear(); refresh(ctx)
        }
    }
    fun receiveMac(ctx: Context, event: JSONObject, valid: () -> Boolean, send: (JSONObject) -> Boolean) {
        main.post {
            if (!valid()) return@post
            when (event.optString("type")) {
                "watchMacState" -> {
                    if (!runCatching { UUID.fromString(event.getString("id")) }.isSuccess) return@post
                    mac = event; macAt = SystemClock.elapsedRealtime(); macValid = valid; macSend = send
                    refresh(ctx)
                }
                "watchFindResult" -> {
                    if (event.optString("id") != currentMac()?.optString("id")) return@post
                    val request = event.optString("request")
                    pending.remove(request)?.let { result(ctx, it, request,
                        if (event.optBoolean("success")) "Mac is playing a sound" else "Mac could not play a sound") }
                }
            }
        }
    }
    private fun currentMac(): JSONObject? = mac?.takeIf {
        SystemClock.elapsedRealtime() - macAt in 0 until WearProtocol.LEASE_MS && macValid?.invoke() == true
    }
    fun battery(ctx: Context): JSONObject {
        val status = ctx.registerReceiver(null, IntentFilter(Intent.ACTION_BATTERY_CHANGED))
        val level = status?.getIntExtra(BatteryManager.EXTRA_LEVEL, -1) ?: -1
        val scale = status?.getIntExtra(BatteryManager.EXTRA_SCALE, -1) ?: -1
        val state = status?.getIntExtra(BatteryManager.EXTRA_STATUS, -1)
        return JSONObject().put("level", if (level >= 0 && scale > 0) (100L * level / scale).toInt().coerceIn(0,100) else -1)
            .put("charging", state == BatteryManager.BATTERY_STATUS_CHARGING || state == BatteryManager.BATTERY_STATUS_FULL)
    }
    fun batterySummary(): String {
        val value = currentMac() ?: return "Mac battery unavailable · Mac disconnected"
        val level = value.optInt("level", -1)
        return if (level in 0..100) "Mac battery: $level%" + if (value.optBoolean("charging")) " · charging" else ""
            else "Mac battery unavailable"
    }
    private fun publish(ctx: Context) {
        val current = currentMac()
        if (current != null) macSend?.invoke(battery(ctx).put("type", "watchPhoneBattery").put("id", current.getString("id")))
        Wearable.getNodeClient(ctx).connectedNodes.addOnSuccessListener { nodes -> main.post {
            nodes.forEach { sendState(ctx, it.id) }
        } }
    }
    private fun sendState(ctx: Context, node: String) {
        val current = currentMac()
        val id = UUID.randomUUID().toString()
        val session = WearSessionAccess.token()
        val now = SystemClock.elapsedRealtime()
        leases.entries.removeAll { now - it.value.at >= WearProtocol.LEASE_MS }
        while (leases.size >= 32) leases.remove(leases.keys.first())
        leases[id] = Lease(node, now, session, current?.optString("id") ?: "")
        val state = JSONObject().put("lease", id).put("session", session).put("phone", battery(ctx))
            .put("mac", current ?: JSONObject()).put("bridge", BridgeRuntime.live != null)
        send(ctx, node, WearProtocol.STATE, state)
    }
    fun message(ctx: Context, node: String, path: String, bytes: ByteArray) {
        if (bytes.size > WearProtocol.MAX_BYTES) return
        main.post {
            context = ctx.applicationContext
            Wearable.getNodeClient(ctx).connectedNodes.addOnSuccessListener { nodes -> main.post {
                if (nodes.none { it.id == node }) return@post
                if (path == WearProtocol.REQUEST) { sendState(ctx, node); refresh(ctx); return@post }
                if (path != WearProtocol.COMMAND) return@post
                val value = runCatching { JSONObject(String(bytes, Charsets.UTF_8)) }.getOrNull() ?: return@post
                val request = value.optString("request")
                if (!runCatching { UUID.fromString(request) }.isSuccess || !requests.add(request)) return@post
                while (requests.size > 128) requests.remove(requests.first())
                val action = value.optString("action")
                val leaseId = value.optString("lease")
                val lease = leases[leaseId]
                val target = value.optString("target")
                val current = if (action == "stop") WearSessionAccess.token() else currentMac()?.optString("id") ?: ""
                val advertised = if (action == "stop") lease?.session else lease?.mac
                if (lease?.node != node || advertised != target || !WearCommandPolicy.accepts(action, leaseId,
                        leaseId, SystemClock.elapsedRealtime() - lease.at, target, current)) {
                    result(ctx, node, request, "Connection changed. Try again."); sendState(ctx, node); return@post
                }
                if (action == "stop") {
                    result(ctx, node, request, if (WearSessionAccess.stop(target)) "Ending mirroring…" else "Could not end mirroring")
                } else {
                    if (pending.size >= 4) { result(ctx,node,request,"Please wait before ringing again"); return@post }
                    pending[request] = node
                    val sent = macSend?.invoke(JSONObject().put("type", "watchFindMac").put("id", target).put("ticket", currentMac()?.optString("ticket") ?: "").put("request", request)) == true
                    if (!sent) { pending.remove(request); result(ctx,node,request,"Mac disconnected") }
                    else main.postDelayed({ pending.remove(request)?.let { result(ctx,it,request,"No response from Mac") } }, 5000)
                }
            } }
        }
    }
    private fun result(ctx: Context, node: String, request: String, message: String) =
        send(ctx,node,WearProtocol.RESULT,JSONObject().put("request",request).put("message",message))
    private fun send(ctx: Context, node: String, path: String, value: JSONObject) {
        runCatching { Wearable.getMessageClient(ctx).sendMessage(node,path,value.toString().toByteArray(Charsets.UTF_8)) }
    }
}
