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
import app.droidmirror.bluetooth.LeftBehindExperiments
import org.json.JSONArray
import java.text.DateFormat
import java.util.Date

/** Owned by the background bridge. BLE callbacks and preference changes run on the main queue. */
class LeftBehindMonitor(private val context: Context) : AutoCloseable {
    companion object {
        private const val KEY = "leftBehindAlerts"
        private const val CHANNEL = "left-behind"
        private const val NOTIFICATION = 8041
        fun enabled(context: Context) = context.getSharedPreferences("left-behind", Context.MODE_PRIVATE).getBoolean(KEY, false)
        fun setEnabled(context: Context, enabled: Boolean) {
            context.getSharedPreferences("left-behind", Context.MODE_PRIVATE).edit().putBoolean(KEY, enabled).apply()
            BridgeRuntime.live?.refreshLeftBehind()
        }
        fun alertsEnabled(context: Context, index: Int) = context.getSharedPreferences("left-behind", Context.MODE_PRIVATE)
            .getBoolean("radio-v1-alerts-${index + 1}", index != 0)
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
            return LeftBehindExperiments.NAMES.mapIndexed { index, name ->
                "#${index + 1} $name: ${prefs.getLong("radio-v1-fires-${index + 1}", 0)} notification posts (${if (alertsEnabled(context, index)) "alerts on" else "alerts muted; still monitored"})\n${prefs.getString("radio-v1-status-${index + 1}", "Not measured yet")}\nProbes: ${prefs.getLong("radio-v1-success-${index + 1}", 0)} successes, ${prefs.getLong("radio-v1-miss-${index + 1}", 0)} misses, ${prefs.getLong("radio-v1-unavailable-${index + 1}", 0)} unavailable"
            }.joinToString("\n\n") + "\n\nRecent alert/recovery history (new build onward):\n" +
                runCatching {
                    val entries = JSONArray(prefs.getString("radio-history", "[]"))
                    (0 until entries.length()).joinToString("\n") { entries.getString(it) }
                }.getOrDefault("") + "\nCounts are notification submissions, not proof of a sound/banner or a separate visible card. #4 must first succeed nearby to arm.\n\n" + LeftBehindFeedback.summary(context)
        }
        fun resetStats(context: Context) {
            val edit = context.getSharedPreferences("left-behind", Context.MODE_PRIVATE).edit()
            repeat(LeftBehindExperiments.COUNT) { index ->
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
    private val state = LeftBehindExperiments()
    private val peers = mutableSetOf<String>()
    private var closed = false
    private var listening = false
    private var active = false
    private var lastProbe = -60_000L
    private var warmup = true
    private val probes = PresenceRadioProbes(context) { index, present, detail ->
        val now = SystemClock.elapsedRealtime()
        if (present == true && state.notified(index)) record(context, "#${index + 1} Mac detected again; alert retained until dismissed")
        if (present == null) state.unavailable(index) else state.observation(index, present, now)
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
        repeat(LeftBehindExperiments.COUNT) {
            LeftBehindFeedback.finishAlgorithm(context, it, "bridge stopped, disabled or reset")
            notifications.cancel(NOTIFICATION + it)
        }
    }
    init { LeftBehindFeedback.reconcile(context); notifications.cancel(NOTIFICATION + 4); if (!alertsEnabled(context, 0)) notifications.cancel(NOTIFICATION); refresh() }
    fun refresh() {
        if (closed) return
        active = enabled(context) && sensor != null
        probes.cancel()
        warmup = true
        lastProbe = -60_000L
        state.reset()
        if (active && peers.isNotEmpty()) state.present()
        handler.removeCallbacks(graceExpired)
        if (active) { listen(); handler.post(graceExpired) }
        else { sensors.cancelTriggerSensor(motion, sensor); listening = false; cancelNotifications() }
    }
    fun presence(peer: String, present: Boolean) {
        if (closed) return
        if (present) peers.add(peer) else peers.remove(peer)
        if (!active) return
        if (peers.isNotEmpty()) {
            warmup = true
            if (state.notified(0)) record(context, "#1 Mac detected again")
            state.present()
            context.getSharedPreferences("left-behind", Context.MODE_PRIVATE).edit().putString("radio-v1-status-1", "Authenticated BLE link present").apply()
        }
        else {
            state.disconnected(SystemClock.elapsedRealtime())
            context.getSharedPreferences("left-behind", Context.MODE_PRIVATE).edit().putString("radio-v1-status-1", "Authenticated BLE link disconnected").apply()
        }
    }
    fun suspendRadioProbes() { probes.cancel() }
    fun disarm() {
        handler.removeCallbacks(graceExpired)
        peers.clear()
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
        repeat(LeftBehindExperiments.COUNT) { index ->
            if (!alertsEnabled(context, index) || !state.eligible(index, now)) return@repeat
            val number = index + 1
            val id = NOTIFICATION + index
            val open = PendingIntent.getActivity(context, id, Intent(context, BridgeSettingsActivity::class.java),
                PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE)
            val detail = "#$number: ${LeftBehindExperiments.NAMES[index]}. Your phone is moving and this Bluetooth detector cannot see your Mac. Check that you have your Mac. Sleep and radio interruptions can cause false alerts."
            val event = LeftBehindFeedback.create(context, index, detail)
            try {
                notifications.notify(id, Notification.Builder(context, CHANNEL)
                    .setSmallIcon(app.droidmirror.bluetooth.R.drawable.ic_left_behind)
                    .setContentTitle("MacBook left behind? #$number")
                    .setContentText(detail).setStyle(Notification.BigTextStyle().bigText(detail))
                    .addAction(Notification.Action.Builder(null, "Correct", LeftBehindFeedback.intent(context, event, "correct")).build())
                    .addAction(Notification.Action.Builder(null, "Incorrect", LeftBehindFeedback.intent(context, event, "incorrect")).build())
                    .setDeleteIntent(LeftBehindFeedback.intent(context, event, "dismissed"))
                    .addExtras(android.os.Bundle().apply { putString("leftBehindEvent", event) })
                    .setShowWhen(true).setContentIntent(open).setAutoCancel(false).setCategory(Notification.CATEGORY_REMINDER).build())
                LeftBehindFeedback.posted(context, event, index)
                state.delivered(index)
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
