package app.droidmirror.bluetooth.bridge

import org.json.JSONArray

/** Preserve complete cards; image previews can be fetched through the asset channel. */
internal object ActivityLayoutBudget {
    /** Native sports rows use semantic identities, not source pixel boxes. This
     * leaves room for five-set matches and context graphics within the same frame. */
    fun compactSports(nodes: JSONArray) {
        val teams = (0 until nodes.length()).map { nodes.getJSONObject(it) }
            .filter { it.optString("sportsField") == "logo" }.map { it.optInt("sportsTeam") }.toSet()
        if (!teams.containsAll(listOf(1, 2))) return
        for (i in 0 until nodes.length()) {
            val node = nodes.getJSONObject(i)
            if (node.has("sportsField")) listOf("x", "y", "width", "height").forEach(node::remove)
        }
    }
    fun fit(nodes: JSONArray, maximumBytes: Int = 3400) {
        fun size() = nodes.toString().toByteArray(Charsets.UTF_8).size
        if (size() <= maximumBytes) return
        for (i in 0 until nodes.length()) nodes.getJSONObject(i).remove("image")
        if (size() <= maximumBytes) return
        // Geometry, content and image revisions take priority over optional styling.
        for (key in listOf("color", "bold", "size")) {
            for (i in 0 until nodes.length()) nodes.getJSONObject(i).remove(key)
            if (size() <= maximumBytes) return
        }
        var limit = 160
        while (size() > maximumBytes && limit > 0) {
            for (i in 0 until nodes.length()) {
                val node = nodes.getJSONObject(i)
                if (node.has("text")) node.put("text", ConversationPayload.boundedText(node.getString("text"), limit))
            }
            limit /= 2
        }
    }
}
