package app.droidmirror.bluetooth.bridge

import android.app.Notification
import android.app.RemoteInput
import android.app.ActivityOptions
import android.app.PendingIntent
import android.app.NotificationManager
import android.content.Intent
import android.os.Bundle
import android.os.Build
import android.service.notification.NotificationListenerService
import android.service.notification.StatusBarNotification
import org.json.JSONArray
import org.json.JSONObject
import java.security.MessageDigest
import java.util.UUID
import android.graphics.Bitmap
import android.graphics.Canvas
import android.util.Base64
import java.io.ByteArrayOutputStream

/** PendingIntents stay on Android. BLE carries only opaque IDs and bounded text. */
class PhoneNotifications : NotificationListenerService() {
    companion object { @Volatile var live: PhoneNotifications? = null }
    private data class Entry(val notification: StatusBarNotification, val version: String)
    private val entries = LinkedHashMap<String, Entry>()
    private val icons = LinkedHashMap<String, String>()
    @Synchronized private fun appIcon(packageName: String): String? {
        icons[packageName]?.let { return it }
        return runCatching {
            val drawable = packageManager.getApplicationIcon(packageName)
            var encoded: String? = null
            for (size in listOf(48, 32, 24, 16)) {
                val bitmap = Bitmap.createBitmap(size, size, Bitmap.Config.ARGB_8888)
                val originalBounds = android.graphics.Rect(drawable.bounds)
                drawable.setBounds(0, 0, size, size)
                drawable.draw(Canvas(bitmap)); drawable.bounds = originalBounds
                val output = ByteArrayOutputStream()
                bitmap.compress(Bitmap.CompressFormat.PNG, 100, output); bitmap.recycle()
                val bytes = output.toByteArray()
                if (bytes.size <= 2048) { encoded = Base64.encodeToString(bytes, Base64.NO_WRAP); break }
            }
            encoded?.also {
                icons[packageName] = it
                while (icons.size > 128) icons.remove(icons.keys.first())
            }
        }.getOrNull()
    }
    private fun id(key: String) = MessageDigest.getInstance("SHA-256").digest(key.toByteArray())
        .joinToString("") { "%02x".format(it) }
    private fun bounded(value: CharSequence?, bytes: Int): String {
        var result = value?.toString().orEmpty().take(bytes)
        while (result.toByteArray(Charsets.UTF_8).size > bytes) result = result.dropLast(1)
        return result
    }
    private fun eligible(sbn: StatusBarNotification): Boolean = sbn.packageName != packageName && !sbn.isOngoing &&
        sbn.notification.visibility != Notification.VISIBILITY_SECRET &&
        sbn.notification.flags and Notification.FLAG_GROUP_SUMMARY == 0
    override fun onListenerConnected() {
        live = this
        activeNotifications?.filter(::eligible)?.takeLast(128)?.forEach { remember(it) }
    }
    override fun onListenerDisconnected() { live = null; synchronized(this) { entries.clear() } }
    override fun onDestroy() { live = null; super.onDestroy() }
    @Synchronized private fun remember(sbn: StatusBarNotification): Entry {
        val entry = Entry(sbn, UUID.randomUUID().toString())
        entries[id(sbn.key)] = entry
        while (entries.size > 128) entries.remove(entries.keys.first())
        return entry
    }
    private fun payload(entry: Entry): JSONObject {
        val sbn = entry.notification
        val notification = sbn.notification
        val ranking = Ranking()
        val silent = currentRanking.getRanking(sbn.key, ranking) && ranking.importance < NotificationManager.IMPORTANCE_DEFAULT
        // VISIBILITY_PRIVATE governs Android's lock-screen presentation, not
        // whether a user-authorized notification listener can forward content.
        // Use only the notification supplied by Android: platform redaction
        // remains intact, and VISIBILITY_SECRET is still excluded by eligible().
        val label = runCatching { packageManager.getApplicationLabel(packageManager.getApplicationInfo(sbn.packageName, 0)) }
            .getOrDefault("Android app")
        val actions = JSONArray()
        notification.actions?.take(3)?.forEachIndexed { index, action ->
            actions.put(JSONObject().put("id", index.toString()).put("title", bounded(action.title, 80))
                .put("reply", action.remoteInputs?.count { it.allowFreeFormInput } == 1))
        }
        val result = JSONObject().put("type", "notification").put("id", id(sbn.key)).put("version", entry.version)
            .put("silent", silent)
            .put("app", bounded(label, 120)).put("title", bounded(notification.extras.getCharSequence(Notification.EXTRA_TITLE), 240))
            .put("body", bounded(
                notification.extras.getCharSequence(Notification.EXTRA_BIG_TEXT) ?: notification.extras.getCharSequence(Notification.EXTRA_TEXT), 1200))
            .put("actions", actions)
        appIcon(sbn.packageName)?.let { icon ->
            result.put("appIcon", icon)
            // Preserve transport size limits; missing icons never block delivery.
            if (result.toString().toByteArray(Charsets.UTF_8).size > 7600) result.remove("appIcon")
        }
        return result
    }
    override fun onNotificationPosted(sbn: StatusBarNotification) {
        if (!eligible(sbn)) return
        BridgeRuntime.live?.sendEvent(payload(remember(sbn)))
    }
    override fun onNotificationRemoved(sbn: StatusBarNotification) {
        val key = id(sbn.key)
        synchronized(this) { entries.remove(key) }
        BridgeRuntime.live?.sendEvent(JSONObject().put("type", "removed").put("id", key))
    }
    @Synchronized fun snapshot(): List<JSONObject> = entries.values.sortedBy { it.notification.postTime }
        .map { payload(it).put("snapshot", true) }
    private fun sendIntent(intent: PendingIntent, fill: Intent? = null) {
        val options = if (Build.VERSION.SDK_INT >= 34) ActivityOptions.makeBasic().apply {
            // Only reached for an authenticated, explicit Mac notification click.
            // This opts into existing BAL privileges; it does not bypass Android's policy.
            setPendingIntentBackgroundActivityStartMode(if (Build.VERSION.SDK_INT >= 36)
                ActivityOptions.MODE_BACKGROUND_ACTIVITY_START_ALLOW_ALWAYS else ActivityOptions.MODE_BACKGROUND_ACTIVITY_START_ALLOWED)
        }.toBundle() else null
        intent.send(this, 0, fill, null, null, null, options)
    }
    @Synchronized fun perform(command: JSONObject): Boolean = runCatching {
        val entry = entries[command.getString("id")] ?: return false
        check(entry.version == command.getString("version"))
        check(activeNotifications.any { it.key == entry.notification.key })
        val notification = entry.notification.notification
        val action = command.getString("action")
        if (action == "open") {
            sendIntent(requireNotNull(notification.contentIntent))
        } else {
            val index = action.toInt(); require(index in 0..2)
            val selected = requireNotNull(notification.actions?.getOrNull(index))
            val text = command.optString("text")
            val replyInputs = selected.remoteInputs?.filter { it.allowFreeFormInput }.orEmpty()
            if (replyInputs.isNotEmpty()) {
                check(replyInputs.size == 1 && text.isNotEmpty() && text.toByteArray().size <= 4096)
                val fill = Intent()
                RemoteInput.addResultsToIntent(replyInputs.toTypedArray(), fill, Bundle().apply { putCharSequence(replyInputs[0].resultKey, text) })
                if (Build.VERSION.SDK_INT >= 28) RemoteInput.setResultsSource(fill, RemoteInput.SOURCE_FREE_FORM_INPUT)
                sendIntent(selected.actionIntent, fill)
            } else {
                check(text.isEmpty())
                sendIntent(selected.actionIntent)
            }
        }
        true
    }.getOrDefault(false)
}
