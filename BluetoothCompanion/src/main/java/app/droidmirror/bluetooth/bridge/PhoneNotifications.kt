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
    private fun encodeImage(drawable: android.graphics.drawable.Drawable, photo: Boolean, maximumBytes: Int, content: Boolean = false): String? {
        if (maximumBytes < 256) return null
        val originalBounds = android.graphics.Rect(drawable.bounds)
        try {
            for (size in if (content) listOf(256, 192, 128, 96, 64, 48, 32, 24, 16)
                else if (photo) listOf(96, 64, 48, 32, 24, 16) else listOf(48, 32, 24, 16)) {
                val ratio = if (content && drawable.intrinsicWidth > 0 && drawable.intrinsicHeight > 0)
                    size.toDouble() / maxOf(drawable.intrinsicWidth, drawable.intrinsicHeight) else 1.0
                val width = if (content) maxOf(1, (drawable.intrinsicWidth.coerceAtLeast(1) * ratio).toInt()).coerceAtMost(size) else size
                val height = if (content) maxOf(1, (drawable.intrinsicHeight.coerceAtLeast(1) * ratio).toInt()).coerceAtMost(size) else size
                val bitmap = Bitmap.createBitmap(width, height, Bitmap.Config.ARGB_8888)
                val output = ByteArrayOutputStream()
                try {
                    val canvas = Canvas(bitmap)
                    if (photo) canvas.drawColor(android.graphics.Color.WHITE)
                    drawable.setBounds(0, 0, width, height)
                    drawable.draw(canvas)
                    bitmap.compress(if (photo) Bitmap.CompressFormat.JPEG else Bitmap.CompressFormat.PNG, 80, output)
                } finally { bitmap.recycle() }
                val bytes = output.toByteArray()
                if (bytes.size <= maximumBytes) return Base64.encodeToString(bytes, Base64.NO_WRAP)
            }
            return null
        } finally { drawable.bounds = originalBounds }
    }
    @Synchronized private fun appIcon(packageName: String): String? {
        icons[packageName]?.let { return it }
        return runCatching {
            encodeImage(packageManager.getApplicationIcon(packageName), false, 1024)?.also {
                icons[packageName] = it
                while (icons.size > 128) icons.remove(icons.keys.first())
            }
        }.getOrNull()
    }
    private fun messages(notification: Notification): List<Notification.MessagingStyle.Message> {
        val bundles = if (Build.VERSION.SDK_INT >= 33) notification.extras.getParcelableArray(
            Notification.EXTRA_MESSAGES, Bundle::class.java)
            else @Suppress("DEPRECATION") notification.extras.getParcelableArray(Notification.EXTRA_MESSAGES)
        return if (bundles == null) emptyList() else Notification.MessagingStyle.Message.getMessagesFromBundleArray(bundles)
    }
    private fun contactImage(notification: Notification, maximumBytes: Int): String? = runCatching {
        // Only notification-provided images: no Contacts access or remote downloads.
        val messages = messages(notification)
        val person = if (Build.VERSION.SDK_INT >= 28) messages.lastOrNull()?.senderPerson else null
        val personImage = runCatching { person?.icon?.loadDrawable(this) }.getOrNull()
        val drawable = personImage ?: runCatching { notification.getLargeIcon()?.loadDrawable(this) }.getOrNull() ?: return null
        encodeImage(drawable, true, maximumBytes)
    }.getOrNull()
    private fun contentDrawable(notification: Notification): android.graphics.drawable.Drawable? = runCatching {
        val extras = notification.extras
        val pictureIcon = if (Build.VERSION.SDK_INT >= 33)
            extras.getParcelable(Notification.EXTRA_PICTURE_ICON, android.graphics.drawable.Icon::class.java)
            else if (Build.VERSION.SDK_INT >= 31) @Suppress("DEPRECATION")
                extras.getParcelable<android.graphics.drawable.Icon>(Notification.EXTRA_PICTURE_ICON) else null
        pictureIcon?.loadDrawable(this)?.let { return it }
        val bitmap = if (Build.VERSION.SDK_INT >= 33) extras.getParcelable(Notification.EXTRA_PICTURE, Bitmap::class.java)
            else @Suppress("DEPRECATION") extras.getParcelable<Bitmap>(Notification.EXTRA_PICTURE)
        bitmap?.let { return android.graphics.drawable.BitmapDrawable(resources, it) }
        val message = messages(notification).lastOrNull() ?: return null
        val uri = message.dataUri ?: return null
        if (message.dataMimeType?.startsWith("image/") != true || uri.scheme !in listOf("content", "android.resource")) return null
        android.graphics.drawable.Icon.createWithContentUri(uri).loadDrawable(this)
    }.getOrNull()
    private fun id(key: String) = MessageDigest.getInstance("SHA-256").digest(key.toByteArray())
        .joinToString("") { "%02x".format(it) }
    private fun bounded(value: CharSequence?, bytes: Int): String {
        var result = value?.toString().orEmpty().take(bytes)
        while (result.toByteArray(Charsets.UTF_8).size > bytes) result = result.dropLast(1)
        return result
    }
    private fun eligible(sbn: StatusBarNotification): Boolean = NotificationForwardingPolicy.eligible(
        sbn.packageName, packageName, sbn.tag, sbn.notification.flags, sbn.notification.visibility)
    override fun onListenerConnected() {
        synchronized(this) { entries.clear() }
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
            .put("postedAt", sbn.postTime)
            .put("silent", silent).put("package", sbn.packageName)
            .put("ongoing", sbn.isOngoing)
            .put("persistent", notification.flags and (Notification.FLAG_NO_CLEAR or Notification.FLAG_FOREGROUND_SERVICE) != 0)
            .put("app", bounded(label, 120)).put("title", bounded(notification.extras.getCharSequence(Notification.EXTRA_TITLE), 240))
            .put("body", bounded(
                notification.extras.getCharSequence(Notification.EXTRA_BIG_TEXT) ?: notification.extras.getCharSequence(Notification.EXTRA_TEXT), 1200))
            .put("actions", actions)
        val conversationMessages = messages(notification)
        val latestMessage = conversationMessages.lastOrNull()
        val isMessage = latestMessage != null || notification.category == Notification.CATEGORY_MESSAGE
        result.put("isMessage", isMessage)
        if (isMessage) {
            val person = if (Build.VERSION.SDK_INT >= 28) latestMessage?.senderPerson else null
            val sender = person?.name ?: @Suppress("DEPRECATION") latestMessage?.sender
                ?: notification.extras.getCharSequence(Notification.EXTRA_TITLE)
            val name = bounded(sender, 120)
            result.put("sender", name).put("senderID", id(sbn.packageName + ":" + (person?.key ?: name)))
                .put("conversation", bounded(notification.extras.getCharSequence(Notification.EXTRA_CONVERSATION_TITLE), 120))
        }
        if (conversationMessages.isNotEmpty()) {
            val items = conversationMessages.map { message ->
                val person = if (Build.VERSION.SDK_INT >= 28) message.senderPerson else null
                val sender = person?.name ?: @Suppress("DEPRECATION") message.sender
                    ?: notification.extras.getCharSequence(Notification.EXTRA_SELF_DISPLAY_NAME) ?: "You"
                val text = message.text?.toString() ?: when {
                    message.dataMimeType?.startsWith("image/") == true -> "[Image]"
                    message.dataMimeType?.startsWith("audio/") == true -> "[Audio]"
                    message.dataMimeType?.startsWith("video/") == true -> "[Video]"
                    else -> "[Attachment]"
                }
                JSONObject().put("sender", sender.toString()).put("text", text).put("timestamp", message.timestamp)
                    .put("outgoing", if (Build.VERSION.SDK_INT >= 28) message.senderPerson == null else @Suppress("DEPRECATION") (message.sender == null))
            }
            val history = ConversationPayload.messages(items)
            result.put("messages", history).put("messagesOmitted", items.size - history.length())
            // Older Mac builds still get a useful latest-message fallback.
            result.put("body", ConversationPayload.boundedText(items.last().getString("text"), 512))
        }
        // AES-GCM + Base64 + the encrypted JSON envelope must fit the 8192-byte
        // fragment limit. Leave room for sequence numbers and snapshot metadata.
        val maximumPayloadBytes = 5800
        appIcon(sbn.packageName)?.let { icon ->
            result.put("appIcon", icon)
            if (result.toString().toByteArray(Charsets.UTF_8).size > maximumPayloadBytes) result.remove("appIcon")
        }
        val picture = contentDrawable(notification)
        val remaining = maximumPayloadBytes - result.toString().toByteArray(Charsets.UTF_8).size - 64
        val avatarBudget = if (picture != null) minOf(1536, remaining / 8 * 3) else minOf(4096, remaining / 4 * 3)
        contactImage(notification, avatarBudget)?.let { image ->
            result.put("contactImage", image)
            if (result.toString().toByteArray(Charsets.UTF_8).size > maximumPayloadBytes) result.remove("contactImage")
        }
        if (picture != null) {
            val mediaBudget = minOf(4096, (maximumPayloadBytes - result.toString().toByteArray(Charsets.UTF_8).size - 64) / 4 * 3)
            runCatching { encodeImage(picture, true, mediaBudget, content = true) }.getOrNull()?.let { image ->
                result.put("contentImage", image)
                if (result.toString().toByteArray(Charsets.UTF_8).size > maximumPayloadBytes) result.remove("contentImage")
            }
        }
        return result
    }
    override fun onNotificationPosted(sbn: StatusBarNotification) {
        if (!eligible(sbn)) {
            // An update can turn a previously forwarded item into an ongoing
            // service notification. Remove its Mac copy as well as its action.
            val key = id(sbn.key)
            val removed = synchronized(this) { entries.remove(key) != null }
            if (removed) BridgeRuntime.live?.sendEvent(JSONObject().put("type", "removed").put("id", key))
            return
        }
        BridgeRuntime.live?.sendEvent(payload(remember(sbn)))
    }
    override fun onNotificationRemoved(sbn: StatusBarNotification) {
        val key = id(sbn.key)
        synchronized(this) { entries.remove(key) }
        BridgeRuntime.live?.sendEvent(JSONObject().put("type", "removed").put("id", key))
    }
    @Synchronized fun snapshot(): List<JSONObject> {
        // Purge Mac copies forwarded by older builds without removing Android's
        // own remote-use history. Small tombstones precede the bounded snapshot.
        val history = activeNotifications.orEmpty().filter {
            NotificationForwardingPolicy.remoteUseAudit(it.packageName, it.tag)
        }.take(16).map { JSONObject().put("type", "removed").put("id", id(it.key)) }
        return history + entries.values.sortedBy { it.notification.postTime }.takeLast(16)
            .map { payload(it).put("snapshot", true) }
    }
    @Synchronized fun dismiss(command: JSONObject): Boolean = runCatching {
        val key = command.getString("id")
        val entry = entries[key]
        // Retrying an already completed dismissal is harmless. Never interpret
        // an unknown action token as permission to cancel an active notification.
        if (entry == null) return activeNotifications.none { id(it.key) == key }
        val current = activeNotifications.firstOrNull { it.key == entry.notification.key } ?: return true
        check(entry.version == command.getString("version"))
        check(current.postTime == entry.notification.postTime)
        check(eligible(current) && current.isClearable)
        cancelNotification(current.key)
        true
    }.getOrDefault(false)

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
