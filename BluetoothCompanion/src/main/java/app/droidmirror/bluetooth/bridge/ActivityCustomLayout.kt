package app.droidmirror.bluetooth.bridge

import android.app.Notification
import android.content.Context
import android.graphics.Bitmap
import android.graphics.Canvas
import android.graphics.Rect
import android.os.Looper
import android.util.Base64
import android.view.View
import android.view.ViewGroup
import android.widget.FrameLayout
import android.widget.ImageView
import android.widget.ProgressBar
import android.widget.TextView
import org.json.JSONArray
import org.json.JSONObject
import java.io.ByteArrayOutputStream
import kotlin.math.round

/** Adapt the public inflated hierarchy to native Mac text/image/progress primitives.
 * No screenshots, private RemoteViews fields, or executable content crosses the link.
 */
internal object ActivityCustomLayout {
    private val images = LinkedHashMap<Notification, Map<String, android.graphics.drawable.Drawable>>()
    @Synchronized fun imageDrawables(n: Notification): Map<String, android.graphics.drawable.Drawable> = images[n].orEmpty()
    private val cache = LinkedHashMap<Notification, JSONObject?>()
    @Synchronized fun read(context: Context, notification: Notification): JSONObject? {
        if (cache.containsKey(notification)) return cache[notification]
        val remote = notification.bigContentView ?: notification.contentView ?: return null
        if (Looper.myLooper() != Looper.getMainLooper()) return null
        val result = runCatching {
            val parent = FrameLayout(context)
            val root = remote.apply(context, parent)
            val density = context.resources.displayMetrics.density
            val width = (340 * density).toInt()
            root.measure(View.MeasureSpec.makeMeasureSpec(width, View.MeasureSpec.EXACTLY),
                View.MeasureSpec.makeMeasureSpec((380 * density).toInt(), View.MeasureSpec.AT_MOST))
            val height = root.measuredHeight.coerceAtLeast(1)
            parent.addView(root)
            parent.layout(0, 0, width, height)
            root.layout(0, 0, width, height)
            val nodes = JSONArray()
            val assets = linkedMapOf<String, android.graphics.drawable.Drawable>()
            fun fraction(value: Double) = round(value * 1000) / 1000
            fun visit(view: View, depth: Int) {
                if (view.visibility != View.VISIBLE || depth > 12 || nodes.length() >= 24) return
                val rect = Rect()
                view.getDrawingRect(rect)
                parent.offsetDescendantRectToMyCoords(view, rect)
                val node = JSONObject().put("x", fraction(rect.left.toDouble() / width))
                    .put("y", fraction(rect.top.toDouble() / height))
                    .put("width", fraction(rect.width().toDouble() / width))
                    .put("height", fraction(rect.height().toDouble() / height))
                when (view) {
                    is TextView -> if (view.text.isNotBlank()) {
                        node.put("kind", "text").put("text", ConversationPayload.boundedText(view.text.toString(), 180))
                            .put("size", round(view.textSize / density)).put("bold", view.typeface?.isBold == true)
                            .put("color", view.currentTextColor.toLong() and 0xffffffffL)
                        nodes.put(node)
                    }
                    is ProgressBar -> {
                        node.put("kind", "progress").put("progress", view.progress.toDouble() / view.max.coerceAtLeast(1))
                        nodes.put(node)
                    }
                    is ImageView -> view.drawable?.let { drawable ->
                        val bitmap = Bitmap.createBitmap(24, 24, Bitmap.Config.ARGB_8888)
                        val bounds = Rect(drawable.bounds)
                        val output = ByteArrayOutputStream()
                        try {
                            drawable.setBounds(0, 0, 24, 24); drawable.draw(Canvas(bitmap))
                            bitmap.compress(Bitmap.CompressFormat.PNG, 100, output)
                            assets["customNodes/${nodes.length()}/image"] = drawable
                            node.put("kind", "image").put("imageRevision", java.security.MessageDigest.getInstance("SHA-256")
                                .digest(output.toByteArray()).joinToString("") { "%02x".format(it) })
                            if (output.size() <= 384) node.put("image", Base64.encodeToString(output.toByteArray(), Base64.NO_WRAP))
                            nodes.put(node)
                        } finally { drawable.bounds = bounds; bitmap.recycle() }
                    }
                }
                if (view is ViewGroup) for (i in 0 until view.childCount) visit(view.getChildAt(i), depth + 1)
            }
            visit(root, 0)
            while (nodes.length() > 0 && nodes.toString().toByteArray(Charsets.UTF_8).size > 2000) nodes.remove(nodes.length() - 1)
            images[notification] = assets.filterKeys { it.split("/")[1].toInt() < nodes.length() }
            if (nodes.length() == 0) null else JSONObject().put("nodes", nodes).put("height", height / density)
        }.getOrNull()
        cache[notification] = result
        while (cache.size > 32) { val first = cache.keys.first(); cache.remove(first); images.remove(first) }
        return result
    }
}
