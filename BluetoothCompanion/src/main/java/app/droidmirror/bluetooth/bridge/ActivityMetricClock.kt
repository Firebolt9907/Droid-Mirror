package app.droidmirror.bluetooth.bridge

import android.app.Notification
import android.content.Context
import android.os.Build
import java.time.Duration
import java.time.Instant

/** Public Android 17 MetricStyle API, resolved at runtime while retaining compile SDK 36. */
internal object ActivityMetricClock {
    data class Value(val label: String, val baseElapsedMs: Long?, val pausedMs: Long?, val countDown: Boolean)
    fun read(context: Context, notification: Notification, sampledElapsed: Long, sampledWall: Long): Value? {
        if (Build.VERSION.SDK_INT < 37) return null
        val style = runCatching { Notification.Builder.recoverBuilder(context, notification).style }.getOrNull() ?: return null
        return readStyle(style, sampledElapsed, sampledWall)
    }
    fun readStyle(style: Any, sampledElapsed: Long, sampledWall: Long): Value? {
        return runCatching {
            if (style.javaClass.name != "android.app.Notification\$MetricStyle") return null
            val metrics = style.javaClass.getMethod("getMetrics").invoke(style) as? List<*> ?: emptyList<Any>()
            val critical = style.javaClass.getMethod("getCriticalMetric").invoke(style)
            (listOfNotNull(critical) + metrics.filterNotNull()).firstNotNullOfOrNull { metric ->
                val value = metric.javaClass.getMethod("getValue").invoke(metric) ?: return@firstNotNullOfOrNull null
                if (value.javaClass.name != "android.app.Notification\$Metric\$TimeDifference") return@firstNotNullOfOrNull null
                val down = value.javaClass.getMethod("isTimer").invoke(value) == true
                if (!down && value.javaClass.getMethod("isStopwatch").invoke(value) != true) return@firstNotNullOfOrNull null
                val paused = value.javaClass.getMethod("getPausedDuration").invoke(value) as? Duration
                val elapsed = value.javaClass.getMethod("getZeroElapsedRealtime").invoke(value) as? Long
                val wall = value.javaClass.getMethod("getZeroTime").invoke(value) as? Instant
                val base = elapsed ?: wall?.let { sampledElapsed - (sampledWall - it.toEpochMilli()) }
                if (paused == null && base == null) return@firstNotNullOfOrNull null
                Value(metric.javaClass.getMethod("getLabel").invoke(metric)?.toString().orEmpty(), base, paused?.toMillis()?.coerceAtLeast(0), down)
            }
        }.getOrNull()
    }
}
