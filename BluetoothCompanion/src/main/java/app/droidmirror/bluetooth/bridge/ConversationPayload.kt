package app.droidmirror.bluetooth.bridge

import org.json.JSONArray
import org.json.JSONObject

/** Keep recent unread messages in Android's order, within the encrypted wire budget. */
object ConversationPayload {
    fun boundedText(value: String, maximumBytes: Int): String {
        if (value.toByteArray(Charsets.UTF_8).size <= maximumBytes) return value
        if (maximumBytes < 3) return ""
        val budget = maximumBytes - 3
        var end = value.offsetByCodePoints(0, minOf(budget, value.codePointCount(0, value.length)))
        while (value.substring(0, end).toByteArray(Charsets.UTF_8).size > budget)
            end = value.offsetByCodePoints(end, -1)
        return value.substring(0, end) + "…"
    }

    fun messages(values: List<JSONObject>): JSONArray {
        val recent = values.takeLast(12).map { value ->
            JSONObject().put("sender", boundedText(value.optString("sender"), 80))
                .put("text", boundedText(value.optString("text"), 1024))
                .put("timestamp", value.optLong("timestamp"))
                .put("outgoing", value.optBoolean("outgoing"))
        }.toMutableList()
        // Text takes priority over icons and media. The outer payload reserves
        // additional room for actions, the latest-message fallback and images.
        while (recent.size > 1 && JSONArray(recent).toString().toByteArray(Charsets.UTF_8).size > 2800)
            recent.removeAt(0)
        // JSON escaping can expand control characters beyond their UTF-8 size.
        while (recent.size == 1 && JSONArray(recent).toString().toByteArray(Charsets.UTF_8).size > 2800) {
            val message = recent[0]
            val text = message.getString("text")
            message.put("text", boundedText(text, text.toByteArray(Charsets.UTF_8).size / 2))
        }
        return JSONArray(recent)
    }
}
