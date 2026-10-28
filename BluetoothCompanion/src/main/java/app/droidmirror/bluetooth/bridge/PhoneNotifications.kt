package app.droidmirror.bluetooth.bridge

import android.app.Notification
import android.app.RemoteInput
import android.app.ActivityOptions
import android.app.PendingIntent
import android.app.NotificationManager
import android.app.KeyguardManager
import android.content.Intent
import android.os.Bundle
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.os.SystemClock
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
    private data class Entry(val notification: StatusBarNotification, val version: String, @Volatile var imageRevision: String? = null)
    private val entries = LinkedHashMap<String, Entry>()
    private val icons = LinkedHashMap<String, String>()
    private val imageAssets = ActivityImageAssets()
    private var imageThread: android.os.HandlerThread? = null
    private var imageHandler: Handler? = null
    @Synchronized private fun currentImageSource(id: String): Entry? = entries[id]?.takeIf {
        live === this && eligible(it.notification) && ActivityNotification.isActivity(it.notification.notification)
    }
    fun imageManifest(command: JSONObject, done: (JSONObject) -> Unit) {
        val entry = currentImageSource(command.optString("id"))
        if (entry == null) {
            done(JSONObject().put("success", false)); return
        }
        val handler = synchronized(this) {
            imageHandler ?: Handler(android.os.HandlerThread("DroidMirrorActivityImages").also { it.start(); imageThread = it }.looper).also { imageHandler = it }
        }
        var waits = 0
        fun build() {
            if (entry.imageRevision == null && waits++ < 80) { handler.postDelayed({ build() }, 25); return }
            if (command.optString("imageRevision").isNotEmpty() && entry.imageRevision != command.optString("imageRevision")) {
                done(JSONObject().put("success", false).put("stale", true)); return
            }
            val manifest = JSONObject()
            val n = entry.notification.notification
            val drawables = linkedMapOf<String, android.graphics.drawable.Drawable>()
            fun add(key: String, load: () -> android.graphics.drawable.Drawable?) { runCatching { load() }.getOrNull()?.let { drawables[key] = it } }
            add("appIcon") { packageManager.getApplicationIcon(entry.notification.packageName) }
            add("activityIcon") { n.smallIcon?.loadDrawable(this) }
            add("contactImage") {
                val person = if (Build.VERSION.SDK_INT >= 28) messages(n).lastOrNull()?.senderPerson else null
                person?.icon?.loadDrawable(this) ?: n.getLargeIcon()?.loadDrawable(this)
            }
            add("contentImage") { contentDrawable(n) }
            if (Build.VERSION.SDK_INT >= 36) runCatching {
                val style = Notification.Builder.recoverBuilder(this, n).style as? Notification.ProgressStyle
                add("progressStartIcon") { style?.progressStartIcon?.loadDrawable(this) }
                add("progressEndIcon") { style?.progressEndIcon?.loadDrawable(this) }
                add("progressTrackerIcon") { style?.progressTrackerIcon?.loadDrawable(this) }
            }
            drawables.putAll(ActivityCustomLayout.imageDrawables(n))
            drawables.forEach { (field, drawable) -> runCatching {
                val isolated = drawable.constantState?.newDrawable(resources)?.mutate() ?: drawable
                isolated.state = drawable.state; isolated.level = drawable.level; isolated.alpha = drawable.alpha
                isolated.layoutDirection = drawable.layoutDirection
                imageAssets.encode(isolated, field)?.let { manifest.put(field, imageAssets.remember(it)) }
            } }
            done(if (currentImageSource(command.optString("id")) != null)
                JSONObject().put("success", true).put("images", manifest).put("imageRevision", entry.imageRevision) else JSONObject().put("success", false))
        }
        handler.post { build() }
    }
    fun imageChunk(command: JSONObject): JSONObject =
        if (currentImageSource(command.optString("id")) == null) JSONObject().put("success", false)
        else imageAssets.chunk(command.optString("asset"), command.optInt("offset", -1))?.put("success", true)
            ?: JSONObject().put("success", false)

    private val openHandler = Handler(Looper.getMainLooper())
    private var pendingOpen: Runnable? = null
    private var pendingOpenResult: ((Boolean) -> Unit)? = null

    private fun cancelOpen() {
        pendingOpen?.let { openHandler.removeCallbacks(it) }
        pendingOpen = null
        val result = pendingOpenResult
        pendingOpenResult = null
        result?.invoke(false)
    }

    private fun opensApp(notification: Notification, action: String): Boolean =
        if (action == "open") notification.contentIntent != null
        else action.toIntOrNull()?.takeIf { it in 0..2 }?.let { index ->
            notification.actions?.getOrNull(index)?.actionIntent?.let { Build.VERSION.SDK_INT >= 31 && it.isActivity }
        } == true

    @Synchronized fun requiresMirror(command: JSONObject): Boolean {
        val entry = entries[command.optString("id")] ?: return false
        return entry.version == command.optString("version") && opensApp(entry.notification.notification, command.optString("action"))
    }

    /** Only an authenticated explicit open may wait for the user to unlock. */
    fun openAfterUnlock(command: JSONObject, authorized: () -> Boolean, result: (Boolean) -> Unit) {
        val gate = NotificationOpenGate(SystemClock.elapsedRealtime())
        openHandler.post {
            // A newer click replaces the old destination instead of opening several apps.
            cancelOpen()
            pendingOpenResult = result
            val task = object : Runnable {
                override fun run() {
                    // Keep the BLE lock outside the listener lock (BLE also calls snapshot/dismiss).
                    val trusted = authorized()
                    val outcome = synchronized(this@PhoneNotifications) {
                        runCatching {
                            val entry = entries[command.getString("id")]
                            val current = live === this@PhoneNotifications && entry != null &&
                                entry.version == command.getString("version") &&
                                opensApp(entry.notification.notification, command.optString("action")) &&
                                activeNotifications.any { it.key == entry.notification.key && it.postTime == entry.notification.postTime }
                            val locked = getSystemService(KeyguardManager::class.java).isKeyguardLocked
                            when (gate.poll(SystemClock.elapsedRealtime(), locked, trusted, current)) {
                                NotificationOpenGate.Decision.WAIT -> null
                                NotificationOpenGate.Decision.OPEN -> perform(command)
                                else -> false
                            }
                        }.getOrDefault(false)
                    }
                    if (outcome == null) openHandler.postDelayed(this, 200)
                    else {
                        pendingOpen = null
                        val callback = pendingOpenResult
                        pendingOpenResult = null
                        callback?.invoke(outcome)
                    }
                }
            }
            pendingOpen = task
            task.run()
        }
    }
    private fun encodeImage(drawable: android.graphics.drawable.Drawable, photo: Boolean, maximumBytes: Int, content: Boolean = false): String? {
        if (maximumBytes < 256) return null
        val originalBounds = android.graphics.Rect(drawable.bounds)
        val lossless = !photo || drawable !is android.graphics.drawable.BitmapDrawable
        try {
            for (size in if (content) listOf(256, 192, 128, 96, 64, 48, 32, 24, 16)
                else if (photo) listOf(96, 64, 48, 32, 24, 16) else listOf(96, 64, 48, 32, 24, 16)) {
                val ratio = if (content && drawable.intrinsicWidth > 0 && drawable.intrinsicHeight > 0)
                    size.toDouble() / maxOf(drawable.intrinsicWidth, drawable.intrinsicHeight) else 1.0
                val width = if (content) maxOf(1, (drawable.intrinsicWidth.coerceAtLeast(1) * ratio).toInt()).coerceAtMost(size) else size
                val height = if (content) maxOf(1, (drawable.intrinsicHeight.coerceAtLeast(1) * ratio).toInt()).coerceAtMost(size) else size
                val bitmap = Bitmap.createBitmap(width, height, Bitmap.Config.ARGB_8888)
                val output = ByteArrayOutputStream()
                try {
                    val canvas = Canvas(bitmap)
                    if (photo && !lossless) canvas.drawColor(android.graphics.Color.WHITE)
                    drawable.setBounds(0, 0, width, height)
                    drawable.draw(canvas)
                    bitmap.compress(if (lossless) Bitmap.CompressFormat.PNG else Bitmap.CompressFormat.JPEG, 80, output)
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
    private fun hasProgress(notification: Notification): Boolean =
        notification.extras.getBoolean(Notification.EXTRA_PROGRESS_INDETERMINATE, false) ||
            (notification.extras.getInt(Notification.EXTRA_PROGRESS_MAX, 0) > 0 &&
                notification.extras.getInt(Notification.EXTRA_PROGRESS, 0) <
                    notification.extras.getInt(Notification.EXTRA_PROGRESS_MAX, 0))
    private fun eligible(sbn: StatusBarNotification): Boolean {
        if (ActivityNotification.isMedia(sbn.notification)) return false
        if (ActivityNotification.isActivity(sbn.notification)) return NotificationForwardingPolicy.activityEligible(
            sbn.packageName, packageName, sbn.tag, sbn.notification.flags, sbn.notification.visibility)
        return NotificationForwardingPolicy.eligible(
        sbn.packageName, packageName, sbn.tag, sbn.notification.flags, sbn.notification.visibility) &&
        !NotificationForwardingPolicy.routine(sbn.packageName, sbn.notification.category,
            sbn.notification.channelId, hasProgress(sbn.notification))
    }
    override fun onListenerConnected() {
        synchronized(this) { entries.clear() }
        ActivityEmbeddedTimers.clear()
        live = this
        snapshot().forEach { BridgeRuntime.live?.sendEvent(it) }
    }
    override fun onListenerDisconnected() { ActivityEmbeddedTimers.clear(); BridgeRuntime.live?.sendEvent(JSONObject().put("type", "activitiesReset")); live = null; cancelOpen(); synchronized(this) { entries.clear() } }
    override fun onDestroy() { imageThread?.quitSafely(); imageAssets.clear(); ActivityEmbeddedTimers.clear(); live = null; cancelOpen(); super.onDestroy() }
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
                .put("reply", action.remoteInputs?.count { it.allowFreeFormInput } == 1)
                .put("opensApp", Build.VERSION.SDK_INT >= 31 && action.actionIntent.isActivity))
        }
        val result = JSONObject().put("type", "notification").put("id", id(sbn.key)).put("version", entry.version)
            .put("postedAt", sbn.postTime)
            .put("silent", silent).put("package", sbn.packageName)
            .put("category", notification.category).put("channel", notification.channelId)
            .put("channelName", bounded(ranking.channel?.name, 120))
            .put("progress", hasProgress(notification))
            .put("subtitle", bounded(notification.extras.getCharSequence(Notification.EXTRA_SUB_TEXT), 240))
            .put("ongoing", sbn.isOngoing)
            .put("persistent", notification.flags and (Notification.FLAG_NO_CLEAR or Notification.FLAG_FOREGROUND_SERVICE) != 0)
            .put("app", bounded(label, 120)).put("title", bounded(notification.extras.getCharSequence(Notification.EXTRA_TITLE), 240))
            .put("body", bounded(
                notification.extras.getCharSequence(Notification.EXTRA_BIG_TEXT) ?: notification.extras.getCharSequence(Notification.EXTRA_TEXT), 1200))
            .put("actions", actions)
        if (ActivityNotification.isActivity(notification)) {
            val metadata = ActivityNotification.metadata(this, notification)
            metadata.keys().forEach { key -> result.put(key, metadata.get(key)) }
            if (Build.VERSION.SDK_INT >= 36) runCatching {
                val style = Notification.Builder.recoverBuilder(this, notification).style as? Notification.ProgressStyle
                mapOf("progressStartIcon" to style?.progressStartIcon,
                    "progressEndIcon" to style?.progressEndIcon, "progressTrackerIcon" to style?.progressTrackerIcon)
                    .forEach { (key, icon) -> icon?.loadDrawable(this)?.let { drawable ->
                        encodeImage(drawable, false, 384)?.let { result.put(key, it) }
                    } }
            }
            runCatching { notification.smallIcon?.loadDrawable(this) }.getOrNull()?.let {
                encodeImage(it, false, 768)?.let { icon -> result.put("activityIcon", icon) }
            }
        }
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
        ActivityEmbeddedTimers.attach(result, sbn.postTime)
        // AES-GCM + Base64 + the encrypted JSON envelope must fit the 8192-byte
        // fragment limit. Leave room for sequence numbers and snapshot metadata.
        val maximumPayloadBytes = 5200
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
        if (result.optBoolean("activity")) {
            val imageKeys = listOf("appIcon", "activityIcon", "contactImage", "contentImage", "progressStartIcon", "progressEndIcon", "progressTrackerIcon")
            val array = result.optJSONArray("customNodes")
            val source = imageKeys.joinToString("\n") { result.optString(it) } +
                (0 until (array?.length() ?: 0)).joinToString("\n") { array?.optJSONObject(it)?.optString("imageRevision").orEmpty() }
            result.put("activityImageRevision", MessageDigest.getInstance("SHA-256").digest(source.toByteArray())
                .joinToString("") { "%02x".format(it) })
            entry.imageRevision = result.getString("activityImageRevision")
        }
        if (result.toString().toByteArray(Charsets.UTF_8).size > 5400) {
            result.remove("contentImage")
            result.remove("contactImage")
            result.remove("appIcon")
            listOf("progressStartIcon", "progressEndIcon", "progressTrackerIcon").forEach { result.remove(it) }
        }
        if (result.toString().toByteArray(Charsets.UTF_8).size > 5400) {
            listOf("customNodes", "progressSegments", "progressPoints", "lines").forEach { result.remove(it) }
        }
        if (result.toString().toByteArray(Charsets.UTF_8).size > 5400) {
            result.remove("embeddedTimers")
            result.remove("timerSampleElapsedMs")
        }
        return result
    }
    override fun onNotificationPosted(sbn: StatusBarNotification) {
        if (!eligible(sbn)) {
            // An update can make a previously forwarded item ineligible.
            val key = id(sbn.key)
            ActivityEmbeddedTimers.forget(key)
            val removed = synchronized(this) { entries.remove(key) != null }
            if (removed) BridgeRuntime.live?.sendEvent(JSONObject().put("type", "removed").put("id", key))
            return
        }
        BridgeRuntime.live?.sendEvent(payload(remember(sbn)))
    }
    override fun onNotificationRemoved(sbn: StatusBarNotification) {
        val key = id(sbn.key)
        ActivityEmbeddedTimers.forget(key)
        synchronized(this) { entries.remove(key) }
        BridgeRuntime.live?.sendEvent(JSONObject().put("type", "removed").put("id", key))
    }
    @Synchronized fun snapshot(): List<JSONObject> {
        // Re-read Android's current state so listener restarts and dropped removals converge.
        val current = activeNotifications.orEmpty()
        val tombstones = current.filterNot(::eligible).take(16).map {
            JSONObject().put("type", "removed").put("id", id(it.key))
        }
        val active = current.filter(::eligible).takeLast(128)
        val keys = active.map { id(it.key) }.toSet()
        entries.keys.retainAll(keys)
        active.forEach { sbn ->
            val old = entries[id(sbn.key)]
            if (old == null || old.notification.postTime != sbn.postTime) remember(sbn)
        }
        val all = entries.values.sortedBy { it.notification.postTime }
        val activities = all.filter { ActivityNotification.isActivity(it.notification.notification) }
        val ordinary = all.filterNot { ActivityNotification.isActivity(it.notification.notification) }.takeLast(16)
        val snapshot = (activities + ordinary)
            .map {
                val p = payload(it).put("snapshot", true)
                if (p.toString().toByteArray(Charsets.UTF_8).size > 5600) {
                    p.remove("contentImage")
                    p.remove("contactImage")
                    p.remove("appIcon")
                }
                p
            }
        // Keep a full snapshot within the bounded BLE queue, leaving control headroom.
        fun bytes() = snapshot.sumOf { it.toString().toByteArray(Charsets.UTF_8).size * 3 + 512 }
        if (bytes() > 200000) snapshot.forEach { p ->
            listOf("contentImage", "contactImage", "appIcon", "activityIcon", "messages").forEach { p.remove(it) }
            p.put("body", ConversationPayload.boundedText(p.optString("body"), 120))
            p.put("title", ConversationPayload.boundedText(p.optString("title"), 80))
            p.put("subtitle", "")
        }
        if (bytes() > 200000) snapshot.forEach { p ->
            val keep = setOf("type", "id", "version", "activity", "app", "title", "snapshot", "canOpen", "package")
            p.keys().asSequence().toList().filterNot { it in keep }.forEach { p.remove(it) }
            p.put("app", ConversationPayload.boundedText(p.optString("app"), 40))
            p.put("title", ConversationPayload.boundedText(p.optString("title"), 40))
        }
        // Hash IDs are 64 bytes each; a full 128-item manifest needs two bounded messages.
        val membership = activities.map { id(it.notification.key) }.chunked(64).ifEmpty { listOf(emptyList()) }
        val generation = UUID.randomUUID().toString()
        val manifest = membership.mapIndexed { index, ids ->
            JSONObject().put("type", "activitiesReset").put("snapshot", generation)
                .put("part", index).put("parts", membership.size).put("ids", JSONArray(ids))
        }
        return manifest + tombstones + snapshot
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
