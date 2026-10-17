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
    fun key(context: Context): ByteArray? = runCatching {
        app.droidmirror.bluetooth.BlePairing.notificationKey(context)
    }.getOrNull()
    fun b64(data: ByteArray): String = Base64.encodeToString(data, Base64.NO_WRAP)
    fun unb64(data: String): ByteArray = Base64.decode(data, Base64.NO_WRAP)
}

class BleSecureSession(private val master: ByteArray) {
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
            return (data.indices step (maximum - 9)).map { offset ->
                ByteBuffer.allocate(9).put(0xd2.toByte()).putInt(id).putShort(offset.toShort()).putShort(data.size.toShort()).array() +
                    data.copyOfRange(offset, minOf(data.size, offset + maximum - 9))
            }
        }
    }
}
