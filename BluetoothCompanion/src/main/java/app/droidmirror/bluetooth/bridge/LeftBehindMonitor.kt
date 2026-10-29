package app.droidmirror.bluetooth.bridge

import android.Manifest
import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.hardware.Sensor
import android.hardware.SensorManager
import android.hardware.TriggerEvent
import android.hardware.TriggerEventListener
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.os.SystemClock
import app.droidmirror.bluetooth.LeftBehindBeaconState
import org.json.JSONArray
import java.text.DateFormat
import java.util.Date

/** Owned by the background bridge. BLE callbacks and preference changes run on the main queue. */
class LeftBehindMonitor(private val context: Context) : AutoCloseable {
    companion object {
        private const val KEY = "leftBehindAlerts"
        private const val CHANNEL = "left-behind"
        private const val NOTIFICATION = 8041
        const val ALGORITHM = 1 // Preserve original #2 preference, notification, and feedback IDs.
        fun temporary(context: Context) = context.getSharedPreferences("left-behind", Context.MODE_PRIVATE).getBoolean("beacon-live-activity", false)
        fun setTemporary(context: Context, enabled: Boolean) { context.getSharedPreferences("left-behind", Context.MODE_PRIVATE).edit().putBoolean("beacon-live-activity", enabled).apply() }
        fun enabled(context: Context) = context.getSharedPreferences("left-behind", Context.MODE_PRIVATE).getBoolean(KEY, false)
        fun setEnabled(context: Context, enabled: Boolean) {
            context.getSharedPreferences("left-behind", Context.MODE_PRIVATE).edit().putBoolean(KEY, enabled).apply()
            BridgeRuntime.live?.refreshLeftBehind()
        }
        fun alertsEnabled(context: Context, index: Int) = context.getSharedPreferences("left-behind", Context.MODE_PRIVATE)
            .getBoolean("radio-v1-alerts-${index + 1}", index == ALGORITHM)
        fun setAlertsEnabled(context: Context, index: Int, enabled: Boolean) {
            context.getSharedPreferences("left-behind", Context.MODE_PRIVATE).edit().putBoolean("radio-v1-alerts-${index + 1}", enabled).apply()
            if (!enabled) {
                LeftBehindFeedback.finishAlgorithm(context, index, "muted")
                context.getSystemService(NotificationManager::class.java).cancel(NOTIFICATION + index)
            }
        }
        private fun record(context: Context, event: String) {
            val prefs = context.getSharedPreferences("left-behind", Context.MODE_PRIVATE)
            val old = runCatching { JSONArray(prefs.getString("radio-history", "[]")) }.getOrDefault(JSONArray())
            val entries = JSONArray().put("${DateFormat.getDateTimeInstance(DateFormat.SHORT, DateFormat.MEDIUM).format(Date())} $event")
            repeat(minOf(59, old.length())) { entries.put(old.getString(it)) }
            prefs.edit().putString("radio-history", entries.toString()).apply()
        }
        fun stats(context: Context): String {
            val prefs = context.getSharedPreferences("left-behind", Context.MODE_PRIVATE)
            return "Mac BLE beacon (selected detector, formerly #2): ${prefs.getLong("radio-v1-fires-2", 0)} notification posts\n${prefs.getString("radio-v1-status-2", "Not measured yet")}\nProbes: ${prefs.getLong("radio-v1-success-2", 0)} successes, ${prefs.getLong("radio-v1-miss-2", 0)} misses, ${prefs.getLong("radio-v1-unavailable-2", 0)} unavailable" + "\n\nRecent alert/recovery history (new build onward):\n" +
                runCatching {
                    val entries = JSONArray(prefs.getString("radio-history", "[]"))
                    (0 until entries.length()).joinToString("\n") { entries.getString(it) }
                }.getOrDefault("") + "\nCounts are notification submissions, not proof of a sound/banner or a separate visible card. Historical #1/#3/#4 entries below are archived; only the beacon detector runs.\n\n" + LeftBehindFeedback.summary(context)
        }
        fun resetStats(context: Context) {
            val edit = context.getSharedPreferences("left-behind", Context.MODE_PRIVATE).edit()
            for (index in listOf(ALGORITHM)) {
                for (kind in listOf("fires", "success", "miss", "unavailable")) edit.remove("radio-v1-$kind-${index + 1}")
            }
            edit.apply()
        }
        fun supported(context: Context) = context.getSystemService(SensorManager::class.java)
            .getDefaultSensor(Sensor.TYPE_SIGNIFICANT_MOTION) != null
    }
    private val handler = Handler(Looper.getMainLooper())
    private val sensors = context.getSystemService(SensorManager::class.java)
    private val sensor = sensors.getDefaultSensor(Sensor.TYPE_SIGNIFICANT_MOTION)
    private val notifications = context.getSystemService(NotificationManager::class.java)
    private val state = LeftBehindBeaconState()
    private var closed = false
    private var listening = false
    private var active = false
    private var lastProbe = -60_000L
    private var warmup = true
    private val probes = PresenceRadioProbes(context) { present, detail ->
        val index = ALGORITHM
        val now = SystemClock.elapsedRealtime()
        if (present == true) {
            val activity = notifications.activeNotifications.firstOrNull {
                it.id == NOTIFICATION + ALGORITHM
            }
            if (activity != null) {
                LeftBehindFeedback.finishAlgorithm(context, ALGORITHM, "Mac beacon detected again")
                notifications.cancel(activity.id)
                record(context, "Mac beacon detected again; reminder dismissed")
            } else if (state.notified()) record(context, "Mac beacon detected again")
        }
        if (present == null) state.unavailable() else state.observation(present, now)
        context.getSharedPreferences("left-behind", Context.MODE_PRIVATE).edit()
            .putString("radio-v1-status-${index + 1}", detail).apply()
        val prefs = context.getSharedPreferences("left-behind", Context.MODE_PRIVATE)
        val outcome = if (present == true) "success" else if (present == false) "miss" else "unavailable"
        val counter = "radio-v1-$outcome-${index + 1}"
        prefs.edit().putLong(counter, prefs.getLong(counter, 0) + 1).apply()
        evaluate()
    }
    private val motion = object : TriggerEventListener() {
        override fun onTrigger(event: TriggerEvent?) { handler.post {
            listening = false
            if (!closed && active) {
                state.motion(SystemClock.elapsedRealtime())
                evaluate()
                listen()
            }
        } }
    }
    private val graceExpired = object : Runnable {
        override fun run() {
            if (!closed && active) {
                LeftBehindFeedback.reconcile(context)
                evaluate()
                val now = SystemClock.elapsedRealtime()
                if ((warmup || state.moving(now)) && now - lastProbe >= 60_000) {
                    warmup = false; lastProbe = now; probes.run()
                }
                handler.postDelayed(this, 15_000)
            }
        }
    }
    private fun cancelNotifications() {
        repeat(4) {
            LeftBehindFeedback.finishAlgorithm(context, it, "bridge stopped, disabled or reset")
            notifications.cancel(NOTIFICATION + it)
        }
    }
    init {
        LeftBehindFeedback.reconcile(context)
        // Retire experiment notifications, preserving their history and stored counters.
        for (index in listOf(0, 2, 3)) {
            LeftBehindFeedback.finishAlgorithm(context, index, "detector retired")
            notifications.cancel(NOTIFICATION + index)
        }
        notifications.cancel(NOTIFICATION + 4)
        refresh()
    }
    fun refresh() {
        if (closed) return
        active = enabled(context) && sensor != null
        probes.cancel()
        warmup = true
        lastProbe = -60_000L
        state.reset()
        handler.removeCallbacks(graceExpired)
        if (active) { listen(); handler.post(graceExpired) }
        else { sensors.cancelTriggerSensor(motion, sensor); listening = false; cancelNotifications() }
    }
    // Authentication is only a warmup hint; losing this link is no longer a detector.
    fun presence(present: Boolean) { if (!closed && active && present) warmup = true }
    fun suspendRadioProbes() { probes.cancel(); state.unavailable() }
    fun disarm() {
        handler.removeCallbacks(graceExpired)
        probes.cancel()
        warmup = true
        lastProbe = -60_000L
        state.reset()
        cancelNotifications()
        if (!closed && active) handler.post(graceExpired)
    }
    private fun listen() {
        if (!listening && active && sensor != null) listening = sensors.requestTriggerSensor(motion, sensor)
    }
    private fun evaluate() {
        val now = SystemClock.elapsedRealtime()
        if (Build.VERSION.SDK_INT >= 33 && context.checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) != PackageManager.PERMISSION_GRANTED) return
        if (!notifications.areNotificationsEnabled()) return
        notifications.createNotificationChannel(NotificationChannel(CHANNEL, "Mac left behind", NotificationManager.IMPORTANCE_HIGH))
        if (notifications.getNotificationChannel(CHANNEL)?.importance == NotificationManager.IMPORTANCE_NONE) return
        for (index in listOf(ALGORITHM)) {
            if (!alertsEnabled(context, index) || !state.eligible(now)) continue
            val number = index + 1
            val id = NOTIFICATION + index
            val open = PendingIntent.getActivity(context, id, Intent(context, BridgeSettingsActivity::class.java),
                PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE)
            val detail = "Your phone is moving and your Mac’s Bluetooth beacon is absent. Check that you have your Mac. Sleep and radio interruptions can also cause this reminder."
            val event = LeftBehindFeedback.create(context, index, detail)
            try {
                val builder = Notification.Builder(context, CHANNEL)
                    .setSmallIcon(app.droidmirror.bluetooth.R.drawable.ic_left_behind)
                    .setContentTitle("MacBook left behind?")
                    .setContentText(detail).setStyle(Notification.BigTextStyle().bigText(detail))
                    .addAction(Notification.Action.Builder(null, "Dismiss", LeftBehindFeedback.intent(context, event, "dismissed")).build())
                    .setDeleteIntent(LeftBehindFeedback.intent(context, event, "dismissed"))
                    .addExtras(android.os.Bundle().apply { putString("leftBehindEvent", event) })
                    .setShowWhen(true).setContentIntent(open).setAutoCancel(false).setCategory(Notification.CATEGORY_REMINDER)
                if (temporary(context)) {
                    builder.addExtras(android.os.Bundle().apply { putBoolean("leftBehindTemporary", true) })
                    builder.setCategory(Notification.CATEGORY_STATUS).setOngoing(true)
                    if (Build.VERSION.SDK_INT >= 36) {
                        builder.setShortCriticalText("Mac left?")
                        builder.addExtras(android.os.Bundle().apply { putBoolean("android.requestPromotedOngoing", true) })
                    }
                }
                notifications.notify(id, builder.build())
                LeftBehindFeedback.posted(context, event, index)
                state.delivered()
                record(context, "#$number notification posted; ${context.getSharedPreferences("left-behind", Context.MODE_PRIVATE).getString("radio-v1-status-$number", "link absent")}")
                val prefs = context.getSharedPreferences("left-behind", Context.MODE_PRIVATE)
                val key = "radio-v1-fires-$number"
                prefs.edit().putLong(key, prefs.getLong(key, 0) + 1).apply()
            } catch (_: SecurityException) {
                LeftBehindFeedback.discard(context, event)
                // Permission may have been revoked between the check and notify; retry later.
            }
        }
    }

    override fun close() {
        closed = true
        active = false
        sensors.cancelTriggerSensor(motion, sensor)
        handler.removeCallbacksAndMessages(null)
        disarm()
        probes.close()
    }
}
