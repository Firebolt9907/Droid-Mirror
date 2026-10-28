package app.droidmirror.bluetooth.bridge

import android.graphics.Bitmap
import android.graphics.Canvas
import android.graphics.Rect
import android.graphics.drawable.BitmapDrawable
import android.graphics.drawable.Drawable
import android.util.Base64
import org.json.JSONObject
import java.io.ByteArrayOutputStream
import java.security.MessageDigest
import kotlin.math.roundToInt

/** Content-addressed, bounded assets. Vectors are rasterized directly at display resolution into lossless PNG. */
internal class ActivityImageAssets {
    private val cache = LinkedHashMap<String, ByteArray>(32, .75f, true)
    private var bytes = 0
    @Synchronized fun clear() { cache.clear(); bytes = 0 }
    @Synchronized fun remember(data: ByteArray): String {
        val hash = MessageDigest.getInstance("SHA-256").digest(data).joinToString("") { "%02x".format(it) }
        if (!cache.containsKey(hash)) { cache[hash] = data; bytes += data.size }
        while (bytes > 4 * 1024 * 1024 || cache.size > 128) cache.remove(cache.keys.first())?.let { bytes -= it.size }
        return hash
    }
    @Synchronized fun chunk(hash: String, offset: Int): JSONObject? {
        val data = cache[hash] ?: return null
        if (offset < 0 || offset >= data.size || offset % 768 != 0) return null
        return JSONObject().put("asset", hash).put("offset", offset).put("total", data.size)
            .put("data", Base64.encodeToString(data.copyOfRange(offset, minOf(offset + 768, data.size)), Base64.NO_WRAP))
    }
    fun encode(drawable: Drawable, field: String): ByteArray? {
        val maximum = when {
            field == "contentImage" -> 1024
            field == "contactImage" -> 160
            field.startsWith("customNodes/") -> 512
            field.startsWith("progress") -> 64
            else -> 96
        }
        val bitmap = (drawable as? BitmapDrawable)?.bitmap
        if (bitmap?.config == Bitmap.Config.HARDWARE) {
            val software = bitmap.copy(Bitmap.Config.ARGB_8888, false) ?: return null
            try { return encode(BitmapDrawable(android.content.res.Resources.getSystem(), software), field) }
            finally { software.recycle() }
        }
        val sourceWidth = bitmap?.width ?: drawable.intrinsicWidth.coerceAtLeast(1)
        val sourceHeight = bitmap?.height ?: drawable.intrinsicHeight.coerceAtLeast(1)
        val limit = if (bitmap != null) minOf(maximum, maxOf(sourceWidth, sourceHeight)) else maximum
        val aspect = sourceWidth.toDouble() / sourceHeight
        val photo = field == "contentImage" && bitmap != null
        for (edge in listOf(limit, limit * 3 / 4, limit / 2, limit / 4).distinct().filter { it > 0 }) {
            val width = (if (aspect >= 1) edge.toDouble() else edge * aspect).roundToInt().coerceAtLeast(1)
            val height = (if (aspect >= 1) edge / aspect else edge.toDouble()).roundToInt().coerceAtLeast(1)
            val rendered = Bitmap.createBitmap(width, height, Bitmap.Config.ARGB_8888)
            val bounds = Rect(drawable.bounds)
            try {
                val canvas = Canvas(rendered)
                if (photo) canvas.drawColor(android.graphics.Color.WHITE)
                drawable.setBounds(0, 0, width, height); drawable.draw(canvas)
                val output = ByteArrayOutputStream()
                rendered.compress(if (photo) Bitmap.CompressFormat.JPEG else Bitmap.CompressFormat.PNG, 92, output)
                if (output.size() in 1..131072) return output.toByteArray()
            } finally { drawable.bounds = bounds; rendered.recycle() }
        }
        return null
    }
}
