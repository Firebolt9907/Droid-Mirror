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
    private data class ClockBinding(val clock: ActivitySourceGameClock, val changed: (String) -> Unit)
    private val clocks = LinkedHashMap<Notification, List<ClockBinding>>()
    private fun clockReady() = BridgeRuntime.live != null
    private fun activate(notification: Notification) {
        if (!clockReady()) return
        val bindings = clocks[notification] ?: return
        // Bound background widgets independently of the 32-entry layout cache.
        val active = clocks.keys.toList().takeLast(8).toSet()
        clocks.filterKeys { it !in active }.values.flatten().forEach { it.clock.observe(null) }
        if (notification in active) bindings.forEach { it.clock.observe(it.changed) }
    }
    @Synchronized fun pause(notification: Notification) { clocks[notification]?.forEach { it.clock.observe(null) } }
    @Synchronized fun forget(notification: Notification) {
        clocks.remove(notification)?.forEach { it.clock.observe(null) }
        cache.remove(notification); images.remove(notification)
    }
    @Synchronized fun clear() { clocks.values.flatten().forEach { it.clock.observe(null) }; clocks.clear(); cache.clear(); images.clear() }

    @Synchronized fun read(context: Context, notification: Notification, sourcePackage: String? = null): JSONObject? {
        if (cache.containsKey(notification)) {
            if (Looper.myLooper() == Looper.getMainLooper()) activate(notification)
            else android.os.Handler(Looper.getMainLooper()).post { synchronized(this) { if (cache.containsKey(notification)) activate(notification) } }
            return cache[notification]
        }
        val remote = notification.bigContentView ?: notification.contentView ?: return null
        if (Looper.myLooper() != Looper.getMainLooper()) return null
        val result = runCatching {
            val resourcePackage = sourcePackage ?: remote.`package`
            val parent = FrameLayout(context)
            val root = if (resourcePackage == "com.espn.score_center")
                runCatching { remote.apply(ActivitySourceGameClock.inflationContext(context), parent) }.getOrElse { remote.apply(context, parent) }
                else remote.apply(context, parent)
            val observedClocks = mutableListOf<ClockBinding>()
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
            val maximumNodes = if (resourcePackage == "com.espn.score_center") 32 else 24
            val sourceResources = runCatching { context.packageManager.getResourcesForApplication(resourcePackage) }.getOrNull()
            fun resourceName(view: View): String = if (view.id == View.NO_ID) "" else runCatching {
                sourceResources?.getResourceEntryName(view.id)
            }.getOrNull() ?: runCatching { view.resources.getResourceEntryName(view.id) }.getOrDefault("")
            fun alphaMask(drawable: android.graphics.drawable.Drawable): List<Int> {
                val bitmap = Bitmap.createBitmap(24, 24, Bitmap.Config.ARGB_8888)
                val bounds = Rect(drawable.bounds)
                try {
                    drawable.setBounds(0, 0, 24, 24); drawable.draw(Canvas(bitmap))
                    val pixels = IntArray(24 * 24)
                    bitmap.getPixels(pixels, 0, 24, 0, 0, 24, 24)
                    return pixels.map { android.graphics.Color.alpha(it) }
                } finally { drawable.bounds = bounds; bitmap.recycle() }
            }
            val turnIcons by lazy {
                listOf("football_possession" to "possession", "ic_ball_possession" to "possession", "ic_tennis_ball" to "serving").mapNotNull { (name, role) ->
                    runCatching {
                        val res = sourceResources ?: return@runCatching null
                        val id = res.getIdentifier(name, "drawable", resourcePackage)
                        if (id == 0) null else alphaMask(res.getDrawable(id, null)) to role
                    }.getOrNull()
                }
            }
            var playerRows = 0
            fun visit(view: View, depth: Int, inheritedTeam: Int = 0, inheritedRow: Int = 0) {
                if (view.visibility != View.VISIBLE || view.alpha <= 0.01f || depth > 12 || nodes.length() >= maximumNodes) return
                val name = resourceName(view)
                var row = inheritedRow
                if (view is ViewGroup) {
                    val children = (0 until view.childCount).map { view.getChildAt(it) }.filter { it.visibility == View.VISIBLE }
                    if (children.any { resourceName(it).contains("note_label", true) } &&
                        children.any { resourceName(it).contains("note_message", true) }) row = ++playerRows
                }
                val team = ActivitySportsFields.team(name, inheritedTeam)
                val rect = Rect()
                view.getDrawingRect(rect)
                parent.offsetDescendantRectToMyCoords(view, rect)
                val node = JSONObject().put("x", fraction(rect.left.toDouble() / width))
                    .put("y", fraction(rect.top.toDouble() / height))
                    .put("width", fraction(rect.width().toDouble() / width))
                    .put("height", fraction(rect.height().toDouble() / height))
                val turn = ActivitySportsFields.indicator(name, view.contentDescription?.toString().orEmpty())
                    ?: if (view is ImageView && view.drawable != null && name.matches(Regex("iv_live_team_(one|two)_indicator"))) {
                        val mask = alphaMask(view.drawable)
                        turnIcons.firstOrNull { (candidate, _) -> candidate.any { it > 0 } && candidate == mask }?.second
                    } else null
                if (turn != null && team in 1..2) {
                    // Indicators can be plain Views/backgrounds, not just ImageViews.
                    nodes.put(node.put("kind", "indicator").put("sportsTeam", team).put("sportsField", turn))
                    return
                }
                val sourceField = if (resourcePackage == "com.espn.score_center" && view is android.widget.Chronometer && ActivitySportsFields.gameClock(name)) "gameClock"
                    else ActivitySportsFields.field(name, view is ImageView, view is TextView)
                sourceField?.let {
                    if (team in 1..2 || it in listOf("statusPrimary", "statusSecondary", "gameClock", "bases", "setScore", "broadcast")) {
                        node.put("sportsField", it)
                        if (team in 1..2) node.put("sportsTeam", team)
                    }
                }
                val playerField = when {
                    row > 0 && view is TextView && name.contains("note_label", true) -> "playerName"
                    row > 0 && view is TextView && name.contains("note_message", true) -> "playerStats"
                    row > 0 && view is ImageView && name.contains("note_avatar", true) -> "portrait"
                    view is TextView && (name.contains("note", true) || name.contains("leader", true)) -> "note"
                    else -> null
                }
                playerField?.let {
                    node.put("sportsField", it)
                    if (row > 0) node.put("sportsRow", row)
                    if (team in 1..2) node.put("sportsTeam", team)
                }
                when (view) {
                    is TextView -> if (view.text.isNotBlank()) {
                        node.put("kind", "text").put("text", ConversationPayload.boundedText(view.text.toString(), 180))
                            .put("size", round(view.textSize / density)).put("bold", view.typeface?.isBold == true)
                            .put("color", view.currentTextColor.toLong() and 0xffffffffL)
                        nodes.put(node)
                        if (sourceField == "gameClock" && view is ActivitySourceGameClock) {
                            observedClocks += ClockBinding(view) { value ->
                                if (!clockReady()) { view.observe(null) }
                                else if (node.optString("text") != value) {
                                    node.put("text", ConversationPayload.boundedText(value, 180))
                                    PhoneNotifications.live?.sourceClockChanged(notification)
                                }
                            }
                        }
                    }
                    is ProgressBar -> {
                        node.put("kind", "progress").put("progress", view.progress.toDouble() / view.max.coerceAtLeast(1))
                        nodes.put(node)
                    }
                    // Player headshots change with every leader rotation and dominate
                    // the image payload; the Mac footer renders names/stats without them.
                    is ImageView -> if (playerField != "portrait") view.drawable?.let { drawable ->
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
                if (view is ViewGroup) for (i in 0 until view.childCount) visit(view.getChildAt(i), depth + 1, team, row)
            }
            visit(root, 0)
            if (resourcePackage == "com.espn.score_center") ActivityLayoutBudget.compactSports(nodes)
            ActivityLayoutBudget.fit(nodes)
            if (observedClocks.isNotEmpty()) clocks[notification] = observedClocks.take(1)
            images[notification] = assets.filterKeys { it.split("/")[1].toInt() < nodes.length() }
            if (nodes.length() == 0) null else JSONObject().put("nodes", nodes).put("height", height / density)
        }.getOrNull()
        cache[notification] = result
        activate(notification)
        while (cache.size > 32) forget(cache.keys.first())
        return result
    }
}
