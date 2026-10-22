package app.droidmirror.bluetooth.bridge

import org.json.JSONObject

/** Bounded metadata and short leases are shared by every Android proxy callback. */
object MediaSyncProtocol {
    @JvmStatic fun fresh(receivedAt: Long, now: Long): Boolean = now >= receivedAt && now - receivedAt < 8000L
    @JvmStatic fun validSnapshot(event: JSONObject): Boolean {
        if (event.opt("active") != true || event.opt("id") !is String || event.getString("id").length !in 1..128) return false
        for (key in listOf("title", "artist", "album")) {
            if (event.opt(key) !is String || event.getString(key).toByteArray(Charsets.UTF_8).size > 1024) return false
        }
        for (key in listOf("duration", "position")) {
            val value = event.optDouble(key, Double.NaN)
            if (!value.isFinite() || value < 0 || value > 604800) return false
        }
        val actions = event.optJSONArray("actions") ?: return false
        return event.opt("playing") is Boolean && actions.length() <= 8 &&
            (0 until actions.length()).all { actions.optString(it) in listOf("play", "pause", "next", "previous", "seek", "shuffle", "repeat", "queue") }
    }
}

/** One in-flight chunk, one cached cover per direction, tied to snapshot digest. */
class MediaArtworkTransfer {
    companion object {
        const val CHUNK = 4096
        const val MAX_LENGTH = 87384
        fun digest(text: String): String = java.security.MessageDigest.getInstance("SHA-256")
            .digest(text.toByteArray(Charsets.US_ASCII)).joinToString("") { "%02x".format(it.toInt() and 255) }
    }
    private var outgoing = ""
    private var outgoingId = ""
    private var incomingId = ""
    private var expectedLength = 0
    private var incoming = ""
    private var requestedAt = -1000L
    var completed: String? = null
        private set
    fun prepare(event: JSONObject): JSONObject {
        outgoing = (event.remove("artwork") as? String).orEmpty().takeIf { it.length <= MAX_LENGTH }.orEmpty()
        outgoingId = if (outgoing.isEmpty()) "" else digest(outgoing)
        if (outgoingId.isNotEmpty()) event.put("artworkID", outgoingId).put("artworkLength", outgoing.length)
        return event
    }
    fun observe(event: JSONObject) {
        val id = event.optString("artworkID")
        val length = event.optInt("artworkLength")
        if (!id.matches(Regex("[0-9a-f]{64}")) || length !in 1..MAX_LENGTH) { resetIncoming(); return }
        if (id != incomingId || length != expectedLength) {
            resetIncoming(); incomingId = id; expectedLength = length
        }
    }
    fun request(now: Long): JSONObject? {
        if (incomingId.isEmpty() || completed != null || now - requestedAt < 1000) return null
        requestedAt = now
        return JSONObject().put("type", "mediaArtworkRequest").put("artworkID", incomingId).put("offset", incoming.length)
    }
    fun reply(event: JSONObject): JSONObject? {
        val offset = event.optInt("offset", -1)
        if (outgoingId.isEmpty() || event.optString("artworkID") != outgoingId || offset !in outgoing.indices || offset % CHUNK != 0) return null
        return JSONObject().put("type", "mediaArtworkChunk").put("artworkID", outgoingId).put("offset", offset)
            .put("data", outgoing.substring(offset, minOf(offset + CHUNK, outgoing.length)))
    }
    fun receive(event: JSONObject): Boolean {
        val data = event.opt("data") as? String ?: return false
        if (incomingId.isEmpty() || completed != null || event.optString("artworkID") != incomingId ||
            event.optInt("offset", -1) != incoming.length || data.length != minOf(CHUNK, expectedLength - incoming.length) ||
            data.any { it.code > 127 }) return false
        incoming += data; requestedAt = -1000L
        if (incoming.length == expectedLength) {
            if (digest(incoming) == incomingId) completed = incoming else resetIncoming()
        }
        return true
    }
    private fun resetIncoming() {
        incomingId = ""; incoming = ""; expectedLength = 0; completed = null; requestedAt = -1000L
    }
    fun clear() { resetIncoming(); outgoing = ""; outgoingId = "" }
}

/** Queue IDs are scoped to a revision, so delayed watch callbacks cannot select a new row. */
class RemoteMediaQueue {
    private var track = ""
    private var revision = ""
    var value: JSONObject? = null
        private set
    fun observe(snapshot: JSONObject?) {
        val nextTrack = snapshot?.optString("id").orEmpty()
        val nextRevision = snapshot?.optString("queueRevision").orEmpty()
        if (track != nextTrack || revision != nextRevision) value = null
        track = nextTrack; revision = nextRevision
    }
    fun receive(event: JSONObject): Boolean {
        if (track.isEmpty() || !revision.matches(Regex("[0-9a-f]{64}")) ||
            event.optString("id") != track || event.optString("revision") != revision ||
            event.toString().toByteArray(Charsets.UTF_8).size > 5200) return false
        val items = event.optJSONArray("items") ?: return false
        if (items.length() !in 1..32) return false
        val ids = mutableSetOf<Long>()
        for (i in 0 until items.length()) {
            val item = items.optJSONObject(i) ?: return false
            val id = item.opt("queueItemId")
            if ((id !is Long && id !is Int) || (id as Number).toLong() < 0 || !ids.add(id.toLong())) return false
            for (key in listOf("title", "artist")) {
                val text = item.opt(key) as? String ?: return false
                if (text.toByteArray(Charsets.UTF_8).size > 320) return false
            }
        }
        val current = event.opt("currentItemId")
        if ((current !is Long && current !is Int) || !ids.contains((current as Number).toLong())) return false
        value = event
        return true
    }
    fun command(id: Long): JSONObject? {
        val queue = value ?: return null
        val items = queue.getJSONArray("items")
        if ((0 until items.length()).none { items.getJSONObject(it).getLong("queueItemId") == id }) return null
        return JSONObject().put("queueRevision", revision).put("queueItemId", id)
    }
}
