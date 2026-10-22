package app.droidmirror.bluetooth.bridge

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.BroadcastReceiver
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.util.Base64
import java.io.ByteArrayOutputStream
import android.media.MediaDescription
import android.media.MediaMetadata
import android.media.VolumeProvider
import android.media.session.MediaController
import android.media.session.MediaSession
import android.media.session.MediaSessionManager
import android.media.session.PlaybackState
import app.droidmirror.bluetooth.R
import android.os.Bundle
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.os.SystemClock
import org.json.JSONArray
import org.json.JSONObject
import java.util.UUID

/** Main-thread owner. Local Android sessions and the Mac proxy are kept separate. */
class PhoneMediaSync(private val context: Context, private val send: (JSONObject) -> Unit) : AutoCloseable {
    companion object {
        private const val CHANNEL = "mac_media"
        private const val NOTIFICATION = 7314
        var live: PhoneMediaSync? = null
            private set
    }
    private val handler = Handler(Looper.getMainLooper())
    private val manager = context.getSystemService(MediaSessionManager::class.java)
    private val notifications = context.getSystemService(NotificationManager::class.java)
    private val proxy = MediaSession(context, "DroidMirror Apple Music")
    private var local: MediaController? = null
    private var localId = UUID.randomUUID().toString()
    private val artwork = MediaArtworkTransfer()
    private val remoteQueue = RemoteMediaQueue()
    private val route = if (Build.VERSION.SDK_INT >= 30) MacMediaRoute(context) { controllerId ->
        // System UI maps remote playback to the selected route through this ID.
        proxy.setPlaybackToRemote(object : VolumeProvider(VOLUME_CONTROL_FIXED, 1, 1, controllerId) {})
    } else null
    private var remoteArtwork: Bitmap? = null
    private var remote: JSONObject? = null
    private var remoteAt = 0L
    private var closed = false
    private var accessAvailable: Boolean? = null
    private var notificationSignature = ""
    private val poll = object : Runnable {
        override fun run() {
            if (closed) return
            refresh()
            handler.postDelayed(this, 2000)
        }
    }
    init {
        live = this
        notifications.createNotificationChannel(NotificationChannel(CHANNEL, "Apple Music on Mac", NotificationManager.IMPORTANCE_LOW))
        proxy.setPlaybackToRemote(object : VolumeProvider(VOLUME_CONTROL_FIXED, 1, 1) {})
        proxy.setCallback(object : MediaSession.Callback() {
            override fun onPlay() = controlRemote("play")
            override fun onPause() = controlRemote("pause")
            override fun onSkipToQueueItem(id: Long) { controlRemote("queue", queueItemId = id) }
            override fun onSkipToNext() = controlRemote("next")
            override fun onSkipToPrevious() = controlRemote("previous")
            override fun onSeekTo(pos: Long) = controlRemote("seek", pos / 1000.0)
            override fun onCustomAction(action: String, extras: Bundle?) {
                if (action in listOf("shuffle", "repeat")) controlRemote(action)
            }
        }, handler)
        handler.post(poll)
    }
    private fun actions(controller: MediaController): Map<String, Long> {
        val flags = controller.playbackState?.actions ?: 0L
        val supported = mapOf("play" to PlaybackState.ACTION_PLAY, "pause" to PlaybackState.ACTION_PAUSE,
            "next" to PlaybackState.ACTION_SKIP_TO_NEXT, "previous" to PlaybackState.ACTION_SKIP_TO_PREVIOUS,
            "seek" to PlaybackState.ACTION_SEEK_TO).filterValues { flags and it != 0L }.toMutableMap()
        if (flags and PlaybackState.ACTION_PLAY_PAUSE != 0L) {
            supported["play"] = PlaybackState.ACTION_PLAY; supported["pause"] = PlaybackState.ACTION_PAUSE
        }
        return supported
    }
    private fun playing(controller: MediaController?) = controller?.playbackState?.state in
        listOf(PlaybackState.STATE_PLAYING, PlaybackState.STATE_BUFFERING, PlaybackState.STATE_CONNECTING)

    private fun refresh() {
        val query = runCatching {
            manager.getActiveSessions(ComponentName(context, PhoneNotifications::class.java))
                .filter { it.packageName != context.packageName && it.playbackState?.state in
                    listOf(PlaybackState.STATE_PLAYING, PlaybackState.STATE_PAUSED, PlaybackState.STATE_BUFFERING, PlaybackState.STATE_CONNECTING) }
        }
        if (accessAvailable != query.isSuccess) {
            accessAvailable = query.isSuccess
            send(JSONObject().put("type", "mediaStatus").put("message",
                if (query.isSuccess) "" else "Allow notification access on Android for phone media"))
        }
        val sessions = query.getOrDefault(emptyList())
        val selected = sessions.firstOrNull { playing(it) } ?: sessions.firstOrNull()
        if (selected?.sessionToken != local?.sessionToken) localId = UUID.randomUUID().toString()
        local = selected
        val event = JSONObject().put("type", "mediaState").put("active", selected != null)
        if (selected != null) {
            val metadata = selected.metadata
            val state = selected.playbackState
            val position = (state?.position ?: 0L).coerceAtLeast(0) +
                (if (state?.state == PlaybackState.STATE_PLAYING && state.lastPositionUpdateTime > 0)
                    ((SystemClock.elapsedRealtime() - state.lastPositionUpdateTime).coerceAtLeast(0) * state.playbackSpeed).toLong() else 0)
            event.put("id", localId).put("title", metadata?.getString(MediaMetadata.METADATA_KEY_TITLE).orEmpty().take(240))
                .put("artist", metadata?.getString(MediaMetadata.METADATA_KEY_ARTIST).orEmpty().take(240))
                .put("album", metadata?.getString(MediaMetadata.METADATA_KEY_ALBUM).orEmpty().take(240))
                .put("playing", playing(selected)).put("duration", (metadata?.getLong(MediaMetadata.METADATA_KEY_DURATION) ?: 0L).coerceAtLeast(0) / 1000.0)
                .put("position", position / 1000.0).put("actions", JSONArray(actions(selected).keys.toList()))
        }
        if (selected != null) {
            val metadata = selected.metadata
            val cover = runCatching {
                metadata?.getBitmap(MediaMetadata.METADATA_KEY_ALBUM_ART)
                    ?: metadata?.getBitmap(MediaMetadata.METADATA_KEY_ART)
                    ?: metadata?.getBitmap(MediaMetadata.METADATA_KEY_DISPLAY_ICON)
            }.getOrNull()
            if (cover != null) encodeArtwork(cover)?.let {
                event.put("artwork", it)
            }
        }
        send(artwork.prepare(event))
        render()
    }
    fun receive(event: JSONObject) {
        if (closed) return
        when (event.optString("type")) {
            "mediaState" -> {
                remote = event.takeIf { MediaSyncProtocol.validSnapshot(it) }
                remoteQueue.observe(remote)
                artwork.observe(remote ?: JSONObject())
                remoteArtwork = if (remote != null) decodeArtwork(artwork.completed ?: event.opt("artwork")) else null
                remoteAt = SystemClock.elapsedRealtime()
                requestArtwork()
                render()
            }
            "mediaQueue" -> {
                if (remote == null || !MediaSyncProtocol.fresh(remoteAt, SystemClock.elapsedRealtime()) || !remoteQueue.receive(event)) return
                render()
            }
            "mediaArtworkRequest" -> {
                if (local != null) artwork.reply(event)?.let(send)
            }
            "mediaArtworkChunk" -> {
                if (remote == null || !MediaSyncProtocol.fresh(remoteAt, SystemClock.elapsedRealtime()) || !artwork.receive(event)) return
                remoteArtwork = decodeArtwork(artwork.completed)
                requestArtwork(); render()
            }
            "mediaCommand" -> {
                val controller = local ?: return
                if (event.optString("id") != localId) return
                val action = event.optString("action")
                if (!actions(controller).containsKey(action)) return
                // Recheck that Android still advertises this exact session.
                val current = runCatching { manager.getActiveSessions(ComponentName(context, PhoneNotifications::class.java)) }
                    .getOrNull()?.firstOrNull { it.sessionToken == controller.sessionToken } ?: return
                runCatching {
                    when (action) {
                        "play" -> current.transportControls.play()
                        "pause" -> current.transportControls.pause()
                        "next" -> current.transportControls.skipToNext()
                        "previous" -> current.transportControls.skipToPrevious()
                        "seek" -> {
                            val position = event.optDouble("position", Double.NaN)
                            if (position.isFinite() && position in 0.0..604800.0) current.transportControls.seekTo((position * 1000).toLong())
                        }
                    }
                }
                refresh()
            }
        }
    }
    private fun usableRemote(): JSONObject? = remote?.takeIf {
        MediaSyncProtocol.fresh(remoteAt, SystemClock.elapsedRealtime()) && !playing(local)
    }
    fun controlRemote(action: String, position: Double? = null, expectedId: String? = null, queueItemId: Long? = null) {
        if (closed) return
        val value = usableRemote() ?: return
        if (expectedId != null && expectedId != value.optString("id")) return
        val actions = value.getJSONArray("actions")
        if ((0 until actions.length()).none { actions.optString(it) == action }) return
        val command = JSONObject().put("type", "mediaCommand").put("id", value.getString("id")).put("action", action)
        if (action == "seek") {
            if (position == null || !position.isFinite() || position !in 0.0..604800.0) return
            command.put("position", position)
        }
        if (action == "queue") {
            val selection = remoteQueue.command(queueItemId ?: return) ?: return
            command.put("queueRevision", selection.getString("queueRevision"))
                .put("queueItemId", selection.getLong("queueItemId"))
        }
        if (action == "shuffle") command.put("enabled", !value.optBoolean("shuffle"))
        if (action == "repeat") command.put("mode", when (value.optString("repeat")) { "off" -> "all"; "all" -> "one"; else -> "off" })
        send(command)
    }
    private fun requestArtwork() { artwork.request(SystemClock.elapsedRealtime())?.let(send) }
    private fun render() {
        val value = usableRemote()
        if (value == null) {
            route?.setActive(false)
            proxy.isActive = false
            proxy.setMetadata(null)
            proxy.setQueue(null); proxy.setQueueTitle(null)
            proxy.setPlaybackState(PlaybackState.Builder().setState(PlaybackState.STATE_NONE, 0, 0f).build())
            notifications.cancel(NOTIFICATION); notificationSignature = ""
            return
        }
        route?.setActive(true)
        val isPlaying = value.getBoolean("playing")
        val names = value.getJSONArray("actions").let { a -> (0 until a.length()).map { a.getString(it) } }
        val actionMap = mapOf("play" to PlaybackState.ACTION_PLAY, "pause" to PlaybackState.ACTION_PAUSE,
            "next" to PlaybackState.ACTION_SKIP_TO_NEXT, "previous" to PlaybackState.ACTION_SKIP_TO_PREVIOUS, "seek" to PlaybackState.ACTION_SEEK_TO)
        val queue = remoteQueue.value.takeIf { "queue" in names }
        val flags = (if (queue != null) PlaybackState.ACTION_SKIP_TO_QUEUE_ITEM else 0L) or names.fold(0L) { result, name -> result or (actionMap[name] ?: 0L) }
        val metadata = MediaMetadata.Builder().putString(MediaMetadata.METADATA_KEY_TITLE, value.getString("title"))
            .putString(MediaMetadata.METADATA_KEY_ARTIST, value.getString("artist"))
            .putString(MediaMetadata.METADATA_KEY_ALBUM, value.getString("album"))
            .putLong(MediaMetadata.METADATA_KEY_DURATION, (value.getDouble("duration") * 1000).toLong())
        remoteArtwork?.let {
            metadata.putBitmap(MediaMetadata.METADATA_KEY_ALBUM_ART, it).putBitmap(MediaMetadata.METADATA_KEY_ART, it)
        }
        proxy.setMetadata(metadata.build())
        val queueItems = queue?.getJSONArray("items")?.let { entries ->
            (0 until entries.length()).map { index ->
                val item = entries.getJSONObject(index)
                val id = item.getLong("queueItemId")
                MediaSession.QueueItem(MediaDescription.Builder().setMediaId(id.toString())
                    .setTitle(item.getString("title")).setSubtitle(item.getString("artist")).build(), id)
            }
        }
        proxy.setQueue(queueItems)
        proxy.setQueueTitle(if (queueItems != null) "Playing Next · Apple Music on Mac" else null)
        val playback = PlaybackState.Builder().setActions(flags)
        if (queue != null) playback.setActiveQueueItemId(queue.getLong("currentItemId"))
        for (action in listOf("shuffle", "repeat").filter { it in names }) {
            playback.addCustomAction(action, controlLabel(action, value),
                controlIcon(action, value))
        }
        proxy.setPlaybackState(playback.setState(
            if (isPlaying) PlaybackState.STATE_PLAYING else PlaybackState.STATE_PAUSED,
            (value.getDouble("position") * 1000).toLong(), if (isPlaying) 1f else 0f, remoteAt).build())
        proxy.isActive = true
        val signature = listOf(value.getString("id"), value.getString("title"), value.getString("artist"), isPlaying, names, value.optBoolean("shuffle"), value.optString("repeat"), remoteArtwork).toString()
        if (signature == notificationSignature) return
        val builder = Notification.Builder(context, CHANNEL).setSmallIcon(R.drawable.ic_laptop)
            .setContentTitle(value.getString("title")).setContentText(value.getString("artist") + " · Apple Music on Mac")
            .setOnlyAlertOnce(true).setVisibility(Notification.VISIBILITY_PUBLIC)
        remoteArtwork?.let { builder.setLargeIcon(it) }
        val compact = listOf("previous", if (isPlaying) "pause" else "play", "next").filter { it in names }
        val controls = compact + listOf("shuffle", "repeat").filter { it in names }
        for (action in controls) {
            val icon = controlIcon(action, value)
            val intent = Intent(context, MediaControlReceiver::class.java).setAction(action).putExtra("id", value.getString("id"))
            val pending = PendingIntent.getBroadcast(context, action.hashCode(), intent, PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE)
            builder.addAction(Notification.Action.Builder(android.graphics.drawable.Icon.createWithResource(context, icon), controlLabel(action, value), pending).build())
        }
        builder.setStyle(Notification.MediaStyle().setMediaSession(proxy.sessionToken)
            .setShowActionsInCompactView(*compact.indices.toList().toIntArray()))
        runCatching { notifications.notify(NOTIFICATION, builder.build()) }
            .onSuccess { notificationSignature = signature }
    }
    private fun controlIcon(action: String, value: JSONObject): Int = when (action) {
        "previous" -> R.drawable.ic_skip_previous
        "next" -> R.drawable.ic_skip_next
        "pause" -> R.drawable.ic_pause
        "shuffle" -> if (value.optBoolean("shuffle")) R.drawable.ic_shuffle_on else R.drawable.ic_shuffle
        "repeat" -> when (value.optString("repeat", "off")) {
            "one" -> R.drawable.ic_repeat_one_on
            "all" -> R.drawable.ic_repeat_on
            else -> R.drawable.ic_repeat
        }
        else -> R.drawable.ic_play_arrow
    }
    private fun controlLabel(action: String, value: JSONObject): String = when (action) {
        "shuffle" -> if (value.optBoolean("shuffle")) "Shuffle on" else "Shuffle off"
        "repeat" -> "Repeat " + value.optString("repeat", "off")
        else -> action.replaceFirstChar { it.uppercase() }
    }
    private fun encodeArtwork(bitmap: Bitmap): String? = runCatching {
        for (size in listOf(512, 384, 256)) {
            val scale = minOf(1.0, size.toDouble() / maxOf(bitmap.width, bitmap.height))
            val thumbnail = Bitmap.createScaledBitmap(bitmap, maxOf(1, (bitmap.width * scale).toInt()),
                maxOf(1, (bitmap.height * scale).toInt()), true)
            val output = ByteArrayOutputStream()
            try { thumbnail.compress(Bitmap.CompressFormat.JPEG, 85, output) }
            finally { if (thumbnail !== bitmap) thumbnail.recycle() }
            if (output.size() <= 65536) return Base64.encodeToString(output.toByteArray(), Base64.NO_WRAP)
        }
        null
    }.getOrNull()

    private fun decodeArtwork(value: Any?): Bitmap? = runCatching {
        if (value !is String || value.length > MediaArtworkTransfer.MAX_LENGTH) return null
        val bytes = Base64.decode(value, Base64.NO_WRAP)
        if (bytes.size > 65536) return null
        val bounds = BitmapFactory.Options().apply { inJustDecodeBounds = true }
        BitmapFactory.decodeByteArray(bytes, 0, bytes.size, bounds)
        if (bounds.outWidth !in 1..512 || bounds.outHeight !in 1..512) return null
        BitmapFactory.decodeByteArray(bytes, 0, bytes.size)
    }.getOrNull()

    override fun close() {
        closed = true
        handler.removeCallbacksAndMessages(null)
        remote = null; remoteArtwork = null; local = null; remoteQueue.observe(null); artwork.clear(); route?.close()
        proxy.isActive = false; proxy.release()
        notifications.cancel(NOTIFICATION)
        if (live === this) live = null
    }
}

class MediaControlReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        val id = intent.getStringExtra("id") ?: return
        PhoneMediaSync.live?.controlRemote(intent.action ?: return, expectedId = id)
    }
}
