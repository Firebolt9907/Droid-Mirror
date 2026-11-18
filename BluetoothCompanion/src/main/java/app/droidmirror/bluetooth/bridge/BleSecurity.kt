package app.droidmirror.bluetooth.bridge

import android.content.Context
import android.util.Base64
import org.json.JSONObject
import java.nio.ByteBuffer
import java.security.MessageDigest
import java.security.SecureRandom
import javax.crypto.Cipher
import javax.crypto.Mac
import javax.crypto.spec.GCMParameterSpec
import javax.crypto.spec.SecretKeySpec

object BleTrust {
    /** Notification credentials for every trusted computer. */
    fun keys(context: Context): List<Pair<String, ByteArray>> =
        app.droidmirror.bluetooth.ComputerPeers.all(context).mapNotNull { peer ->
            runCatching { app.droidmirror.bluetooth.BlePairing.notificationKey(context, peer) }.getOrNull()?.let { peer to it }
        }
    /** Notification credential of one trusted computer. */
    fun key(context: Context, computer: String): ByteArray? =
        if (!app.droidmirror.bluetooth.ComputerPeers.contains(context, computer)) null
        else runCatching { app.droidmirror.bluetooth.BlePairing.notificationKey(context, computer) }.getOrNull()

    private val legacyAttempts = java.util.concurrent.ConcurrentHashMap<String, Int>()
    /**
     * Chooses the computer whose credential answers a background hello. Current
     * Mac and Linux apps name their key (`keyId`), selecting it exactly. For
     * older Mac apps the identity address is tried, then a sole trusted
     * computer; with two candidates and no hint, successive attempts from that
     * address alternate between them (a wrong guess fails the mutual HMAC
     * handshake and the computer simply reconnects).
     */
    fun computerFor(context: Context, hello: JSONObject, address: String): Pair<String, ByteArray>? {
        val all = keys(context)
        val requested = hello.optString("keyId", "")
        if (requested.isNotEmpty()) {
            val id = runCatching { unb64(requested) }.getOrNull() ?: return null
            return all.firstOrNull { (_, key) ->
                java.security.MessageDigest.isEqual(app.droidmirror.bluetooth.PairingKeys.keyId(key), id)
            }
        }
        all.firstOrNull { it.first == address }?.let { return it }
        if (all.isEmpty()) return null
        val attempt = legacyAttempts.merge(address, 1, Int::plus) ?: 1
        return all[(attempt - 1) % all.size]
    }
    /** Called once a legacy hello authenticated, so the next reconnect starts with the same computer. */
    fun authenticated(address: String) { legacyAttempts.computeIfPresent(address) { _, n -> n - 1 } }
    fun b64(data: ByteArray): String = Base64.encodeToString(data, Base64.NO_WRAP)
    fun unb64(data: String): ByteArray = Base64.decode(data, Base64.NO_WRAP)
}

/** One authenticated background session with one trusted computer. */
class BleSecureSession(private val master: ByteArray, val computer: String) {
    private var macNonce: ByteArray? = null
    private var phoneNonce: ByteArray? = null
    private var incomingKey: ByteArray? = null
    private var outgoingKey: ByteArray? = null
    private var received = 0L
    private var sent = 0L
    @Volatile var authenticated = false
        private set
    private fun hmac(key: ByteArray, data: ByteArray): ByteArray = Mac.getInstance("HmacSHA256").run {
        init(SecretKeySpec(key, "HmacSHA256")); doFinal(data)
    }
    private fun derive(salt: ByteArray, info: String): ByteArray =
        hmac(hmac(salt, master), info.toByteArray(Charsets.UTF_8) + byteArrayOf(1))
    fun hello(objectValue: JSONObject): JSONObject {
        check(macNonce == null)
        val mac = BleTrust.unb64(objectValue.getString("nonce")); require(mac.size == 32)
        val phone = ByteArray(32).also { SecureRandom().nextBytes(it) }
        macNonce = mac; phoneNonce = phone
        return JSONObject().put("type", "challenge").put("nonce", BleTrust.b64(phone))
            .put("proof", BleTrust.b64(hmac(master, "phone".toByteArray() + mac + phone)))
    }
    fun finish(value: JSONObject) {
        check(!authenticated)
        val salt = requireNotNull(macNonce) + requireNotNull(phoneNonce)
        check(MessageDigest.isEqual(hmac(master, "mac".toByteArray() + salt), BleTrust.unb64(value.getString("proof"))))
        incomingKey = derive(salt, "DroidMirror BLE v2 mac")
        outgoingKey = derive(salt, "DroidMirror BLE v2 phone")
        authenticated = true
    }
    private fun nonce(prefix: String, sequence: Long): ByteArray =
        ByteBuffer.allocate(12).put(prefix.toByteArray()).putLong(sequence).array()
    fun seal(value: JSONObject): ByteArray {
        check(authenticated && sent < 9007199254740990L)
        val iv = nonce("DM2P", ++sent)
        val cipher = Cipher.getInstance("AES/GCM/NoPadding")
        cipher.init(Cipher.ENCRYPT_MODE, SecretKeySpec(requireNotNull(outgoingKey), "AES"), GCMParameterSpec(128, iv))
        cipher.updateAAD(iv)
        return JSONObject().put("seq", sent).put("box", BleTrust.b64(iv + cipher.doFinal(value.toString().toByteArray(Charsets.UTF_8))))
            .toString().toByteArray(Charsets.UTF_8)
    }
    fun open(value: JSONObject): JSONObject {
        check(authenticated)
        val sequence = value.getLong("seq")
        check(sequence > received && sequence <= 9007199254740990L)
        val data = BleTrust.unb64(value.getString("box"))
        val iv = nonce("DM2M", sequence)
        check(data.size >= 28 && MessageDigest.isEqual(data.copyOfRange(0, 12), iv))
        val cipher = Cipher.getInstance("AES/GCM/NoPadding")
        cipher.init(Cipher.DECRYPT_MODE, SecretKeySpec(requireNotNull(incomingKey), "AES"), GCMParameterSpec(128, iv))
        cipher.updateAAD(iv)
        val result = JSONObject(String(cipher.doFinal(data.copyOfRange(12, data.size)), Charsets.UTF_8))
        received = sequence
        return result
    }
}

class BleFragments {
    private var id = -1
    private var total = 0
    private var bytes = byteArrayOf()
    private var started = 0L
    fun accept(frame: ByteArray): ByteArray? {
        require(frame.size > 9 && frame[0] == 0xd2.toByte())
        val header = ByteBuffer.wrap(frame)
        header.get(); val message = header.int
        val offset = header.short.toInt() and 65535
        val size = header.short.toInt() and 65535
        require(size in 1..8192)
        if (offset == 0) { id = message; total = size; bytes = byteArrayOf(); started = android.os.SystemClock.elapsedRealtime() }
        check(id == message && total == size && offset == bytes.size &&
            android.os.SystemClock.elapsedRealtime() - started < 15000 && bytes.size + frame.size - 9 <= total)
        bytes += frame.copyOfRange(9, frame.size)
        return if (bytes.size == total) bytes.also { bytes = byteArrayOf(); id = -1 } else null
    }
    companion object {
        fun split(data: ByteArray, id: Int, maximum: Int): List<ByteArray> {
            require(data.size in 1..8192 && maximum > 9)
            // MTU 517 allows 514 ATT payload bytes, but a characteristic value
            // is still limited to 512. Larger frames get truncated on the link.
            val capacity = minOf(maximum, 512) - 9
            return (data.indices step capacity).map { offset ->
                ByteBuffer.allocate(9).put(0xd2.toByte()).putInt(id).putShort(offset.toShort()).putShort(data.size.toShort()).array() +
                    data.copyOfRange(offset, minOf(data.size, offset + capacity))
            }
        }
    }
}
