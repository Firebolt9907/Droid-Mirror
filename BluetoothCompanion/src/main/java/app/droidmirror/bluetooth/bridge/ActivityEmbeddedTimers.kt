package app.droidmirror.bluetooth.bridge

import android.os.SystemClock
import org.json.JSONArray
import org.json.JSONObject

/** Detect after payload text is finalized. Hash + token guards against later snapshot truncation. */
object ActivityEmbeddedTimers {
    private val detector = EmbeddedTimer()
    fun clear() = detector.clear()
    fun forget(id: String) = detector.forget(id)
    fun attach(payload: JSONObject, postedAt: Long) {
        if (!payload.optBoolean("activity") || payload.optBoolean("isMessage")) return
        val now = SystemClock.elapsedRealtime()
        val age = (System.currentTimeMillis() - postedAt).coerceAtLeast(0) / 1000.0
        val clock = payload.optDouble("clockOffsetMs", 0.0) / 1000.0
        val spans = JSONArray()
        fun add(field: String, text: String) {
            detector.observe(payload.optString("id") + "\n" + field, text,
                payload.optBoolean("chronometer"), payload.optBoolean("countDown"), clock, age, now / 1000.0, postedAt)
                .forEach { span -> if (spans.length() < 6) spans.put(JSONObject()
                    .put("hash", text.hashCode()).put("start", span.start).put("end", span.end)
                    .put("rounding", span.rounding).put("token", span.token).put("seconds", span.seconds).put("down", span.down)
                    .put("hours", span.token.count { it == ':' } == 2)
                    .put("width", span.token.substringBefore(':').length)) }
        }
        listOf("title", "body", "subtitle", "status").forEach { add(it, payload.optString(it)) }
        payload.optJSONArray("lines")?.let { lines -> for (i in 0 until lines.length()) add("lines/$i", lines.optString(i)) }
        payload.optJSONArray("customNodes")?.let { nodes -> for (i in 0 until nodes.length()) add("nodes/$i", nodes.optJSONObject(i)?.optString("text") ?: "") }
        if (spans.length() > 0) payload.put("embeddedTimers", spans).put("timerSampleElapsedMs", now)
    }
    fun prepareToSend(payload: JSONObject, now: Long = SystemClock.elapsedRealtime()) {
        val spans = payload.optJSONArray("embeddedTimers") ?: return
        val sampled = payload.optLong("timerSampleElapsedMs", now)
        val age = (now - sampled).coerceAtLeast(0) / 1000.0
        for (i in 0 until spans.length()) spans.getJSONObject(i).let { span ->
            span.put("seconds", (span.getDouble("seconds") + if (span.getBoolean("down")) -age else age).coerceAtLeast(0.0))
        }
        payload.remove("timerSampleElapsedMs")
    }
}
