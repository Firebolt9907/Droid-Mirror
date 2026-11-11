package app.droidmirror.bluetooth.bridge

import org.json.JSONObject
import java.util.UUID

/** Handler-owned UI state. Duplicate race paths contribute their maximum, never their sum. */
class ClipboardSyncProgress {
    data class Transfer(val id: String, val token: String, val sending: Boolean, var size: Int, var bytes: Int = 0, var preparing: Boolean = false)
    private val retired = ArrayDeque<String>()
    private fun retire(id: String) { if (id !in retired) retired.addLast(id); if (retired.size > 128) retired.removeFirst() }
    var current: Transfer? = null; private set
    fun observe(event: JSONObject, sent: Boolean) {
        val id = event.optString("id")
        if (id in retired) return
        when (event.optString("type")) {
            "clipboardFilePrepare" -> {
                if (id.matches(Regex("[A-Fa-f0-9-]{36}")) && current?.id != id) {
                    current?.let { retire(it.id) }
                    current = Transfer(id, UUID.randomUUID().toString(), sent, 0, preparing = true)
                }
            }
            "clipboardFileBegin" -> {
                val size = event.optInt("size", -1)
                if (id.matches(Regex("[A-Fa-f0-9-]{36}")) && size in 0 until 5_000_000 && current?.id != id) {
                    current?.let { retire(it.id) }
                    current = Transfer(id, UUID.randomUUID().toString(), sent, size)
                } else if (current?.id == id && size in 0 until 5_000_000) {
                    current?.size = size; current?.preparing = false
                }
            }
            "clipboardFileChunk" -> {
                val transfer = current ?: return
                if (transfer.id != id || transfer.sending || sent) return
                val encoded = event.optString("data")
                val length = encoded.length / 4 * 3 - encoded.takeLast(2).count { it == '=' }
                val end = event.optInt("offset", -1).toLong() + length
                if (end in 0..transfer.size.toLong()) transfer.bytes = maxOf(transfer.bytes, end.toInt())
            }
            "clipboardFileAck" -> {
                val transfer = current ?: return
                if (transfer.id != id || transfer.preparing || sent == transfer.sending) return
                val offset = event.optInt("offset", -1)
                if (offset !in 0..transfer.size) return
                if (offset == transfer.size) { retire(id); current = null }
                else if (transfer.sending) transfer.bytes = maxOf(transfer.bytes, offset)
            }
            "clipboardFilePrepareEnd", "clipboardFileCancel" -> if (current?.id == id) { retire(id); current = null }
        }
    }
    fun matches(id: String, token: String) = current?.let { it.id == id && it.token == token } == true
    fun clear() { current?.let { retire(it.id) }; current = null }
}
