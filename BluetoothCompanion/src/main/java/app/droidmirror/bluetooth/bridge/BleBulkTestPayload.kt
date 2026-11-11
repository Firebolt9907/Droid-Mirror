package app.droidmirror.bluetooth.bridge

import java.security.MessageDigest

/** Generated-pattern validation only; no Android or clipboard dependencies. */
class BleBulkTestPayload(private val size: Int) {
    var count = 0
        private set
    private val digest = MessageDigest.getInstance("SHA-256")
    private var result: String? = null
    init { require(size in 1..4_000_000) }
    fun append(offset: Int, bytes: ByteArray): Boolean {
        require(result == null && offset == count && bytes.size in 1..3072 && count + bytes.size <= size)
        for (i in bytes.indices) require((bytes[i].toInt() and 255) == (count + i) % 251)
        digest.update(bytes); count += bytes.size
        if (count == size) result = digest.digest().joinToString("") { "%02x".format(it.toInt() and 255) }
        return count == size
    }
    fun sha256(): String = requireNotNull(result)
}
