package app.droidmirror.bluetooth.bridge

import org.json.JSONObject
import java.nio.ByteBuffer
import java.util.UUID
import javax.crypto.Cipher
import javax.crypto.Mac
import javax.crypto.spec.GCMParameterSpec
import javax.crypto.spec.SecretKeySpec

/** Clipboard-only binary AEAD records, independently keyed from the authenticated GATT session. */
class ClipboardBulkCodec(key: ByteArray, token: String, private val macSide: Boolean = false) {
    companion object {
        const val MAXIMUM = 65536
        fun benchmarkKey(master: ByteArray): ByteArray = Mac.getInstance("HmacSHA256").run {
            init(SecretKeySpec(master, "HmacSHA256")); doFinal("DroidMirror synthetic BLE benchmark v1".toByteArray(Charsets.UTF_8))
        }
        val FILES = setOf("clipboardFileBegin", "clipboardFileChunk", "clipboardFileAck", "clipboardFileCancel")
        private val CONTROLS = FILES.minus("clipboardFileChunk") + setOf("clipboardBulkHello", "clipboardBulkReady")
    }
    private var sendingTransfer: Pair<String, Int>? = null
    private var receivingTransfer: Pair<String, Int>? = null
    private fun declaration(event: JSONObject): Pair<String, Int> {
        val id = UUID.fromString(event.getString("id")).toString().uppercase()
        val size = event.getInt("size")
        val destination = event.optString("destination", "clipboard")
        require(destination in setOf("clipboard", "downloads", "install"))
        require(if (destination == "install") app.droidmirror.bluetooth.ApkInstallPolicy.allowed(size.toLong()) && app.droidmirror.bluetooth.ApkInstallPolicy.nameAllowed(event.optString("name")) else size in 0 until app.droidmirror.bluetooth.ClipboardFilePolicy.LIMIT)
        return id to size
    }
    private var sent = 0L
    private var received = 0L
    private val sending: ByteArray
    private val receiving: ByteArray
    init {
        require(key.size == 32 && token.matches(Regex("[a-fA-F0-9]{64}")))
        val salt = token.chunked(2).map { it.toInt(16).toByte() }.toByteArray()
        val extract = hmac(salt, key)
        fun derive(direction: String) = hmac(extract, ("DroidMirror clipboard L2CAP v1 $direction").toByteArray() + byteArrayOf(1))
        sending = derive(if (macSide) "mac" else "phone"); receiving = derive(if (macSide) "phone" else "mac")
    }
    private fun hmac(key: ByteArray, value: ByteArray): ByteArray = Mac.getInstance("HmacSHA256").run {
        init(SecretKeySpec(key, "HmacSHA256")); doFinal(value)
    }
    private fun prefix(outgoing: Boolean) = (if (macSide == outgoing) "DCCM" else "DCCP").toByteArray()
    fun seal(event: JSONObject): ByteArray {
        check(sent < 9007199254740990L)
        val type = event.getString("type")
        if (type == "clipboardFileBegin") sendingTransfer = declaration(event)
        val body = if (type == "clipboardFileChunk") {
            val uuid = UUID.fromString(event.getString("id"))
            val offset = event.getInt("offset"); require(offset >= 0 && sendingTransfer?.first == uuid.toString().uppercase())
            val encoded = event.getString("data"); require(encoded.length <= 4096)
            val bytes = BleTrust.unb64(encoded.replace('-', '+').replace('_', '/')); require(bytes.size in 1..3072 && offset <= (sendingTransfer?.second ?: 0) - bytes.size)
            ByteBuffer.allocate(21 + bytes.size).put(2).putLong(uuid.mostSignificantBits).putLong(uuid.leastSignificantBits).putInt(offset).put(bytes).array()
        } else {
            require(type in CONTROLS)
            byteArrayOf(1) + event.toString().toByteArray(Charsets.UTF_8)
        }
        require(body.size + 24 <= MAXIMUM)
        val seq = sent + 1
        val header = ByteBuffer.allocate(8).putLong(seq).array()
        val iv = prefix(true) + header
        val cipher = Cipher.getInstance("AES/GCM/NoPadding")
        cipher.init(Cipher.ENCRYPT_MODE, SecretKeySpec(sending, "AES"), GCMParameterSpec(128, iv)); cipher.updateAAD(iv)
        val record = header + cipher.doFinal(body)
        sent = seq
        return record
    }
    fun open(record: ByteArray): JSONObject {
        require(record.size in 25..MAXIMUM)
        val seq = ByteBuffer.wrap(record).long
        require(seq == received + 1 && seq <= 9007199254740990L)
        val iv = prefix(false) + record.copyOfRange(0, 8)
        val cipher = Cipher.getInstance("AES/GCM/NoPadding")
        cipher.init(Cipher.DECRYPT_MODE, SecretKeySpec(receiving, "AES"), GCMParameterSpec(128, iv)); cipher.updateAAD(iv)
        val body = cipher.doFinal(record.copyOfRange(8, record.size))
        val result = if (body[0].toInt() == 2) {
            require(body.size in 22..3093)
            val bytes = ByteBuffer.wrap(body); bytes.get()
            val uuid = UUID(bytes.long, bytes.long)
            val offset = bytes.int; require(receivingTransfer?.first == uuid.toString().uppercase() && offset >= 0 && offset <= (receivingTransfer?.second ?: 0) - bytes.remaining())
            val data = ByteArray(bytes.remaining()); bytes.get(data)
            JSONObject().put("type", "clipboardFileChunk").put("id", uuid.toString().uppercase()).put("offset", offset)
                .put("data", BleTrust.b64(data).replace('+', '-').replace('/', '_'))
        } else {
            require(body[0].toInt() == 1)
            JSONObject(String(body.copyOfRange(1, body.size), Charsets.UTF_8)).also { require(it.getString("type") in CONTROLS) }
        }
        if (result.optString("type") == "clipboardFileBegin") receivingTransfer = declaration(result)
        received = seq
        return result
    }
}
