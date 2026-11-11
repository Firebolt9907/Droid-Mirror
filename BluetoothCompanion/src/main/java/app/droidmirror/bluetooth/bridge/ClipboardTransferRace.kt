package app.droidmirror.bluetooth.bridge

import org.json.JSONObject
import java.io.ByteArrayOutputStream
import java.security.MessageDigest

/** Handler-owned arbitration; clipboard destination checks stay in ClipboardFileTransfer. */
class ClipboardTransferRace(private val wire: (Int, JSONObject) -> Boolean,
    private val deliver: (JSONObject) -> Unit, private val won: (Int) -> Unit) {
    var started: () -> Unit = {}
    private val disabled = HashSet<Int>()
    private fun transmit(lane: Int, event: JSONObject): Boolean {
        if (lane in disabled) return false
        val ok = wire(lane, event); if (!ok) disabled.add(lane); return ok
    }
    private val history = ArrayList<JSONObject>()
    private var historyCost = 0
    private var outgoing = ""
    val outgoingID: String? get() = outgoing.takeIf { history.isNotEmpty() }
    private var sent = 0
    private var ack = -1
    private var installLane: Int? = null
    private var installIncoming = false
    private var incoming = ""
    private var size = 0
    private var digest = ""
    private var window = 1
    private val copies = HashMap<Int, ByteArrayOutputStream>()
    private val chunks = HashMap<Int, Int>()
    private val finished = ArrayDeque<String>()
    private var injecting = false
    private var winner = 0
    fun send(event: JSONObject): Boolean {
        val type = event.optString("type"); val id = event.optString("id")
        if (installIncoming && id == incoming && type in setOf("clipboardFileAck", "clipboardFileCancel")) {
            val lane = installLane ?: return false
            val ok = transmit(lane, event)
            if (type == "clipboardFileCancel" || event.optInt("offset", -1) == size) remember(id)
            return ok
        }
        if (id == incoming && type == "clipboardFileAck" && event.optInt("offset", -1) > 0 && event.optInt("offset", -1) != size) return true
        if (type == "clipboardFileBegin") { started(); disabled.clear(); outgoing = id; history.clear(); historyCost = 0; sent = 0; ack = -1 }
        if (type == "clipboardFileBegin" || type == "clipboardFileChunk") {
            val cost = event.toString().toByteArray().size
            if (historyCost + cost > 7_000_000) return false
            history.add(JSONObject(event.toString())); historyCost += cost
            if (type == "clipboardFileChunk") sent += decode(event.getString("data")).size
        }
        if (type == "clipboardFileCancel") {
            remember(id)
            if (id == incoming) { copies.clear(); chunks.clear() }
            if (id == outgoing) { history.clear(); historyCost = 0 }
        }
        val a = transmit(0, event); val b = transmit(1, event)
        if (id == incoming && type == "clipboardFileAck" && event.optInt("offset", -1) == size) { disabled.add(1 - winner); won(winner) }
        return a || b
    }
    fun restartLane(lane: Int) { disabled.remove(lane); copies.remove(lane); chunks.remove(lane) }
    fun catchUp(lane: Int) { for (event in history) if (!wire(lane, event)) break }
    private fun decode(value: String) = BleTrust.unb64(value.replace('-', '+').replace('_', '/'))
    private fun remember(id: String) { finished.addLast(id); if (finished.size > 64) finished.removeFirst() }
    fun receive(event: JSONObject, lane: Int) {
        val id = event.optString("id"); if (!id.matches(Regex("[a-fA-F0-9-]{36}"))) return
        val type = event.optString("type")
        if (type == "clipboardFileAck") {
            val offset = event.optInt("offset", -1)
            if (id != outgoing || offset != sent || offset <= ack) return
            ack = offset
            if (history.firstOrNull()?.optInt("size", -1) == offset && offset > 0) { history.clear(); historyCost = 0 }
            deliver(event); return
        }
        if (id in finished) return
        if (type == "clipboardFileBegin" && event.optString("destination") == "install") {
            val n = event.optInt("size", -1)
            if (!app.droidmirror.bluetooth.ApkInstallPolicy.allowed(n.toLong()) || !app.droidmirror.bluetooth.ApkInstallPolicy.nameAllowed(event.optString("name")) || !event.optString("sha256").matches(Regex("[a-f0-9]{64}"))) return
            if (id != incoming) {
                started(); disabled.clear(); copies.clear(); chunks.clear()
                incoming = id; size = n; installIncoming = true; installLane = lane; winner = lane
                deliver(event)
            }
            return
        }
        if (installIncoming && id == incoming) {
            if (lane == installLane) deliver(event)
            return
        }
        if (type == "clipboardFileCancel") { if (id == outgoing) { history.clear(); historyCost = 0 }; remember(id); deliver(event); return }
        if (type == "clipboardFileBegin") {
            val n = event.optInt("size", -1); val hash = event.optString("sha256")
            if (n !in 0 until 5_000_000 || !hash.matches(Regex("[a-f0-9]{64}"))) return
            if (n == 0 && hash != MessageDigest.getInstance("SHA-256").digest(ByteArray(0)).joinToString("") { "%02x".format(it.toInt() and 255) }) return
            if (id != incoming) {
                installIncoming = false; installLane = null
                started(); disabled.clear(); incoming = id; size = n; digest = hash; window = event.optInt("window", 1).coerceIn(1, 32); copies.clear(); chunks.clear()
                copies[lane] = ByteArrayOutputStream(); chunks[lane] = 0
                if (n == 0) { winner = lane; remember(id) }
                deliver(event)
            } else if (n == size && hash == digest && lane !in copies) {
                copies[lane] = ByteArrayOutputStream(); chunks[lane] = 0
                transmit(lane, JSONObject().put("type", "clipboardFileAck").put("id", id).put("offset", 0).put("window", window))
            }
            return
        }
        if (type != "clipboardFileChunk" || id != incoming) return
        val bytes = copies[lane] ?: return
        if (event.optInt("offset", -1) != bytes.size()) return
        val data = runCatching { decode(event.getString("data")) }.getOrNull() ?: return
        if (data.size !in 1..3072 || bytes.size() + data.size > size) return
        bytes.write(data); chunks[lane] = (chunks[lane] ?: 0) + 1
        if (bytes.size() == size) {
            val complete = bytes.toByteArray()
            if (MessageDigest.getInstance("SHA-256").digest(complete).joinToString("") { "%02x".format(it.toInt() and 255) } != digest) { copies.remove(lane); return }
            remember(id); winner = lane; injecting = true
            for (offset in 0 until size step 3072) deliver(JSONObject().put("type", "clipboardFileChunk").put("id", id).put("offset", offset)
                .put("data", android.util.Base64.encodeToString(complete.copyOfRange(offset, minOf(size, offset + 3072)), android.util.Base64.NO_WRAP)))
            injecting = false; copies.clear(); chunks.clear()
        } else if (chunks.getValue(lane) % window == 0) {
            deliver(JSONObject().put("type", "clipboardFileRaceProgress").put("id", id))
            transmit(lane, JSONObject().put("type", "clipboardFileAck").put("id", id).put("offset", bytes.size()))
        }
    }
}
