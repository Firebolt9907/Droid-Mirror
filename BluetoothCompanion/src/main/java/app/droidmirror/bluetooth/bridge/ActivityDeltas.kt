package app.droidmirror.bluetooth.bridge

import org.json.JSONArray
import org.json.JSONObject
import kotlin.math.abs

/** Baselines describe messages actually framed, never queued or discarded updates. Session-local. */
class ActivityDeltas {
    var enabled = false
    private data class Baseline(val wire: JSONObject, val clockAt: Long, val timersAt: Long)
    private val baselines = LinkedHashMap<String, Baseline>()
    fun encode(value: JSONObject, now: Long): JSONObject {
        val id = value.optString("id")
        if (value.optString("type") == "removed") baselines.remove(id)
        if (value.optString("type") != "notification") return value
        if (!enabled || !value.optBoolean("activity")) { baselines.remove(id); return value }
        val previous = baselines.remove(id)
        fun store(wire: JSONObject, clockAt: Long = now, timersAt: Long = now) {
            baselines[id] = Baseline(JSONObject(wire.toString()), clockAt, timersAt)
            while (baselines.size > 128) baselines.remove(baselines.keys.first())
        }
        if (previous == null || value.optBoolean("snapshot")) { store(value); return value }
        var candidate = JSONObject(value.toString())
        val old = previous.wire
        val clockPredictable = value.optBoolean("chronometer") && old.optBoolean("chronometer") &&
            value.optBoolean("countDown") == old.optBoolean("countDown") && now >= previous.clockAt &&
            abs(value.optDouble("clockOffsetMs") - (old.optDouble("clockOffsetMs") - (now - previous.clockAt))) <= 250
        if (clockPredictable) candidate.put("clockOffsetMs", old.get("clockOffsetMs"))
        val timers = stabilizeTimers(candidate, old, (now - previous.timersAt).coerceAtLeast(0) / 1000.0)
        val timersPredictable = timers != null
        if (timers != null) candidate = timers
        val fields = JSONObject()
        val unset = JSONArray()
        candidate.keys().forEach { key ->
            if (key != "type" && key != "id" && (!old.has(key) || !same(candidate.get(key), old.get(key)) ||
                (key == "clockOffsetMs" && value.optBoolean("chronometer") && !clockPredictable))) fields.put(key, candidate.get(key))
        }
        old.keys().forEach { key -> if (!candidate.has(key) && key != "type" && key != "id") unset.put(key) }
        val delta = JSONObject().put("type", "activityPatch").put("id", id)
            .put("base", old.getString("version")).put("set", fields).put("unset", unset)
        if (delta.toString().toByteArray(Charsets.UTF_8).size >= value.toString().toByteArray(Charsets.UTF_8).size) {
            store(value); return value
        }
        store(candidate, if (clockPredictable) previous.clockAt else now, if (timersPredictable) previous.timersAt else now)
        return delta
    }

    /** Keep the old template/spans when only locally predictable digits changed. */
    private fun stabilizeTimers(value: JSONObject, old: JSONObject, age: Double): JSONObject? {
        val current = value.optJSONArray("embeddedTimers") ?: return null
        val before = old.optJSONArray("embeddedTimers") ?: return null
        if (current.length() != before.length() || current.length() !in 1..6) return null
        for (i in 0 until current.length()) {
            val a = current.getJSONObject(i); val b = before.getJSONObject(i)
            if (listOf("down", "hours", "width", "rounding").any { a.opt(it) != b.opt(it) }) return null
            val expected = (b.getDouble("seconds") + if (b.optBoolean("down")) -age else age).coerceAtLeast(0.0)
            if (abs(a.getDouble("seconds") - expected) > 1.05) return null
        }
        val used = mutableSetOf<Int>()
        fun normalized(text: String, spans: JSONArray): Pair<String, Set<Int>> {
            var result = text
            val ids = mutableSetOf<Int>()
            val matches = (0 until spans.length()).map { it to spans.getJSONObject(it) }
                .filter { it.second.optInt("hash") == text.hashCode() }.sortedByDescending { it.second.optInt("start") }
            var boundary = text.length
            for ((index, span) in matches) {
                val start = span.optInt("start", -1); val end = span.optInt("end", -1)
                if (start < 0 || end <= start || end > boundary || text.substring(start, end) != span.optString("token")) continue
                result = result.replaceRange(start, end, "\u0001timer$index\u0001")
                boundary = start; ids.add(index)
            }
            return result to ids
        }
        fun text(a: String, b: String): String {
            val x = normalized(a, current); val y = normalized(b, before)
            if (x.second.isNotEmpty() && x == y) { used.addAll(x.second); return b }
            return a
        }
        val result = JSONObject(value.toString())
        listOf("title", "body", "subtitle", "status").forEach { key ->
            if (result.has(key) && old.has(key)) result.put(key, text(result.optString(key), old.optString(key)))
        }
        for (key in listOf("lines", "customNodes")) {
            val a = result.optJSONArray(key) ?: continue
            val b = old.optJSONArray(key) ?: continue
            for (i in 0 until minOf(a.length(), b.length())) {
                if (key == "lines") a.put(i, text(a.optString(i), b.optString(i)))
                else {
                    val node = a.optJSONObject(i) ?: continue
                    val prior = b.optJSONObject(i) ?: continue
                    if (node.has("text") && prior.has("text")) node.put("text", text(node.optString("text"), prior.optString("text")))
                }
            }
        }
        if (used.size != current.length()) return null
        result.put("embeddedTimers", JSONArray(before.toString()))
        return result
    }
    private fun same(a: Any, b: Any): Boolean = when {
        a is JSONObject && b is JSONObject -> a.length() == b.length() && a.keys().asSequence().all { b.has(it) && same(a.get(it), b.get(it)) }
        a is JSONArray && b is JSONArray -> a.length() == b.length() && (0 until a.length()).all { same(a.get(it), b.get(it)) }
        else -> a == b
    }
}
