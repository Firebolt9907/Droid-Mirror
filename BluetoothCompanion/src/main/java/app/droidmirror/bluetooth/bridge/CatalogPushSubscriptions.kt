package app.droidmirror.bluetooth.bridge

/** Worker-confined delivery baselines belong to each authenticated subscription, not a local scan. */
class CatalogPushSubscriptions {
    private data class Subscriber(val valid: () -> Boolean, val push: (String) -> Unit, var sent: String? = null)
    private val subscribers = linkedMapOf<String, Subscriber>()
    fun subscribe(peer: String, valid: () -> Boolean, push: (String) -> Unit) {
        prune()
        subscribers[peer] = Subscriber(valid, push)
    }
    fun remove(peer: String) { subscribers.remove(peer) }
    fun active(): Boolean { prune(); return subscribers.isNotEmpty() }
    private fun prune() { subscribers.entries.removeAll { !it.value.valid() } }
    fun publish(snapshot: String) {
        prune()
        subscribers.values.forEach { subscriber ->
            if (subscriber.sent != snapshot && subscriber.valid()) {
                subscriber.push(snapshot)
                subscriber.sent = snapshot
            }
        }
    }
}
