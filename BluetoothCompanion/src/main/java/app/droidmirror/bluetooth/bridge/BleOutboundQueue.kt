package app.droidmirror.bluetooth.bridge

/** Plaintext scheduling keeps authenticated sequence order and whole-message framing. */
class BleOutboundQueue {
    private data class Message(val json: String, val bulk: Boolean, val deadline: Long, val cost: Int, val urgent: Boolean, val key: String?)
    private val messages = mutableListOf<Message>()
    private var controlBurst = 0
    var bytes = 0
        private set

    fun append(json: String, bulk: Boolean, now: Long): Boolean = append(json, bulk, now, false)

    fun append(json: String, bulk: Boolean, now: Long, urgent: Boolean): Boolean {
        return append(json, bulk, now, urgent, null)
    }

    fun append(json: String, bulk: Boolean, now: Long, urgent: Boolean, key: String?): Boolean {
        return append(json, bulk, now, urgent, key, 60000)
    }

    fun append(json: String, bulk: Boolean, now: Long, urgent: Boolean, key: String?, lifetimeMs: Long): Boolean {
        val size = json.toByteArray(Charsets.UTF_8).size
        val cost = size * 3 + 512
        // Never coalesce across snapshots, removals or other control messages.
        val replace = if (key == null) null else messages.asReversed().takeWhile { it.key != null }.firstOrNull { it.key == key }
        if (size > 5800 || bytes - (replace?.cost ?: 0) + cost > 262144) return false
        if (replace != null) { messages.remove(replace); bytes -= replace.cost }
        messages.add(Message(json, bulk, now + lifetimeMs, cost, urgent, key))
        bytes += cost
        return true
    }

    fun next(now: Long): String? {
        val expired = messages.filter { it.deadline <= now }
        expired.forEach { bytes -= it.cost }
        messages.removeAll(expired.toSet())
        if (messages.isEmpty()) return null
        val urgent = messages.indexOfFirst { it.urgent }
        val preferred = if (urgent >= 0) urgent else if (controlBurst >= 4) messages.indexOfFirst { it.bulk } else -1
        val index = if (preferred >= 0) preferred else messages.indexOfFirst { !it.bulk }.coerceAtLeast(0)
        val message = messages.removeAt(index)
        bytes -= message.cost
        controlBurst = if (message.bulk) 0 else (controlBurst + 1).coerceAtMost(4)
        return message.json
    }
}
