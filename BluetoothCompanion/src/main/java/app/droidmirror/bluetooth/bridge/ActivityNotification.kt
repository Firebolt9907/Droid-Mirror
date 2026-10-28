package app.droidmirror.bluetooth.bridge

import android.app.Notification
import android.content.Context
import android.os.Build
import org.json.JSONObject
import org.json.JSONArray

/** Adapted from dynamic-island's LiveUpdate and LiveUpdateText parsers.
 * Only public notification fields are forwarded; RemoteViews and intents stay on Android.
 */
internal object ActivityNotification {
    fun isMedia(n: Notification): Boolean = NotificationForwardingPolicy.media(n.category,
        n.extras.getString(Notification.EXTRA_TEMPLATE), n.extras.containsKey(Notification.EXTRA_MEDIA_SESSION))

    fun isActivity(n: Notification): Boolean = n.flags and (
        Notification.FLAG_ONGOING_EVENT or Notification.FLAG_NO_CLEAR or Notification.FLAG_FOREGROUND_SERVICE
    ) != 0 || n.extras.getBoolean("android.requestPromotedOngoing", false) ||
        (Build.VERSION.SDK_INT >= 36 && !n.shortCriticalText.isNullOrEmpty())

    fun metadata(context: Context, n: Notification): JSONObject {
        val extras = n.extras
        fun text(key: String) = extras.getCharSequence(key)?.toString()?.trim().orEmpty()
        fun normalized(value: String) = value.trim().replace(Regex("\\s+"), " ").lowercase(java.util.Locale.ROOT)
        val title = text(Notification.EXTRA_TITLE)
        val expanded = text(Notification.EXTRA_BIG_TEXT).ifBlank {
            extras.getCharSequenceArray(Notification.EXTRA_TEXT_LINES)?.map { it.toString().trim() }
                ?.filter { it.isNotBlank() }?.distinct()?.joinToString("\n").orEmpty()
        }.ifBlank { text(Notification.EXTRA_TEXT) }
        val body = expanded.takeUnless { normalized(it) == normalized(title) }.orEmpty()
        val detail = text(Notification.EXTRA_SUB_TEXT).takeUnless {
            it.isBlank() || normalized(body).contains(normalized(it)) || normalized(title).contains(normalized(it))
        }.orEmpty()
        val style = if (Build.VERSION.SDK_INT >= 36) runCatching {
            Notification.Builder.recoverBuilder(context, n).style as? Notification.ProgressStyle
        }.getOrNull() else null
        val maximum = if (Build.VERSION.SDK_INT >= 36 && style != null) style.progressMax else extras.getInt(Notification.EXTRA_PROGRESS_MAX)
        val progress = if (Build.VERSION.SDK_INT >= 36 && style != null) style.progress else extras.getInt(Notification.EXTRA_PROGRESS)
        val indeterminate = if (Build.VERSION.SDK_INT >= 36 && style != null) style.isProgressIndeterminate else extras.getBoolean(Notification.EXTRA_PROGRESS_INDETERMINATE)
        // Capture both clocks together; the BLE scheduler subtracts queue age before sealing.
        val sampledAt = android.os.SystemClock.elapsedRealtime()
        val sampledWallTime = System.currentTimeMillis()
        val metricClock = ActivityMetricClock.read(context, n, sampledAt, sampledWallTime)
        val clock = extras.getBoolean(Notification.EXTRA_SHOW_CHRONOMETER) && n.`when` > 0
        val template = extras.getString(Notification.EXTRA_TEMPLATE).orEmpty()
        val custom = ActivityCustomLayout.read(context, n)
        val layout = when {
            template.endsWith("CallStyle") || n.category == Notification.CATEGORY_CALL -> "call"
            style != null || maximum > 0 || indeterminate -> "progress"
            template.endsWith("MessagingStyle") -> "messaging"
            template.endsWith("BigPictureStyle") -> "bigPicture"
            template.endsWith("InboxStyle") -> "inbox"
            custom != null -> "custom"
            template.endsWith("BigTextStyle") -> "bigText"
            else -> "standard"
        }
        val result = JSONObject().put("activity", true).put("layout", layout)
            .put("accentColor", n.color.toLong() and 0xffffffffL)
            .put("dark", context.resources.configuration.uiMode and android.content.res.Configuration.UI_MODE_NIGHT_MASK ==
                android.content.res.Configuration.UI_MODE_NIGHT_YES)
            .put("lines", JSONArray(extras.getCharSequenceArray(Notification.EXTRA_TEXT_LINES)?.take(7)?.map {
                ConversationPayload.boundedText(it.toString(), 180)
            }.orEmpty()))
            .put("body", ConversationPayload.boundedText(body, 1200))
            .put("subtitle", ConversationPayload.boundedText(detail, 240))
            .put("status", ConversationPayload.boundedText(if (Build.VERSION.SDK_INT >= 36) n.shortCriticalText.orEmpty() else "", 80))
            .put("progressMax", maximum.coerceAtLeast(0)).put("progressValue", progress.coerceAtLeast(0))
            .put("indeterminate", indeterminate).put("canOpen", n.contentIntent != null)
            .put("chronometer", clock).put("countDown", extras.getBoolean(Notification.EXTRA_CHRONOMETER_COUNT_DOWN))
            .put("clockOffsetMs", if (clock) n.`when` - sampledWallTime else 0)
            .put("clockSampleElapsedMs", sampledAt)
        if (Build.VERSION.SDK_INT >= 36 && style != null && maximum > 0) {
            result.put("progressPoints", JSONArray(style.progressPoints.take(12).map {
                (it.position.toDouble() / maximum).coerceIn(0.0, 1.0)
            }))
            result.put("progressSegments", JSONArray(style.progressSegments.take(12).map {
                JSONObject().put("fraction", (it.length.toDouble() / maximum).coerceIn(0.0, 1.0))
                    .put("color", it.color.toLong() and 0xffffffffL)
            }))
        }
        metricClock?.let {
            result.put("chronometer", it.pausedMs == null).put("countDown", it.countDown)
                .put("clockOffsetMs", it.baseElapsedMs?.let { base -> base - sampledAt } ?: 0)
            it.pausedMs?.let { duration -> result.put("clockPausedMs", duration) }
            if (title.isBlank()) result.put("title", ConversationPayload.boundedText(it.label.ifBlank { if (it.countDown) "Timer" else "Stopwatch" }, 240))
        }
        custom?.let { result.put("customNodes", it.getJSONArray("nodes")).put("customHeight", it.getDouble("height")) }
        return result
    }
}
