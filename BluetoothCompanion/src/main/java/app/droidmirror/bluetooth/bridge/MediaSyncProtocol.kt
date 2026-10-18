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
        return event.opt("playing") is Boolean && actions.length() <= 5 &&
            (0 until actions.length()).all { actions.optString(it) in listOf("play", "pause", "next", "previous", "seek") }
    }
}
