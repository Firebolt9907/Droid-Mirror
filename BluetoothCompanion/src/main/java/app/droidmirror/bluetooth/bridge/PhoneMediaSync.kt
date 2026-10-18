package app.droidmirror.bluetooth.bridge

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.BroadcastReceiver
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.media.MediaMetadata
import android.media.VolumeProvider
import android.media.session.MediaController
import android.media.session.MediaSession
import android.media.session.MediaSessionManager
import android.media.session.PlaybackState
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
            override fun onSkipToNext() = controlRemote("next")
            override fun onSkipToPrevious() = controlRemote("previous")
            override fun onSeekTo(pos: Long) = controlRemote("seek", pos / 1000.0)
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
        send(event)
        render()
    }
    fun receive(event: JSONObject) {
        if (closed) return
        when (event.optString("type")) {
            "mediaState" -> {
                remote = event.takeIf { MediaSyncProtocol.validSnapshot(it) }
                remoteAt = SystemClock.elapsedRealtime()
                render()
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
    fun controlRemote(action: String, position: Double? = null, expectedId: String? = null) {
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
        send(command)
    }
    private fun render() {
        val value = usableRemote()
        if (value == null) {
            proxy.isActive = false
            proxy.setMetadata(null)
            proxy.setPlaybackState(PlaybackState.Builder().setState(PlaybackState.STATE_NONE, 0, 0f).build())
            notifications.cancel(NOTIFICATION); notificationSignature = ""
            return
        }
        val isPlaying = value.getBoolean("playing")
        val names = value.getJSONArray("actions").let { a -> (0 until a.length()).map { a.getString(it) } }
        val actionMap = mapOf("play" to PlaybackState.ACTION_PLAY, "pause" to PlaybackState.ACTION_PAUSE,
            "next" to PlaybackState.ACTION_SKIP_TO_NEXT, "previous" to PlaybackState.ACTION_SKIP_TO_PREVIOUS, "seek" to PlaybackState.ACTION_SEEK_TO)
        val flags = names.fold(0L) { result, name -> result or (actionMap[name] ?: 0L) }
        proxy.setMetadata(MediaMetadata.Builder().putString(MediaMetadata.METADATA_KEY_TITLE, value.getString("title"))
            .putString(MediaMetadata.METADATA_KEY_ARTIST, value.getString("artist"))
            .putString(MediaMetadata.METADATA_KEY_ALBUM, value.getString("album"))
            .putLong(MediaMetadata.METADATA_KEY_DURATION, (value.getDouble("duration") * 1000).toLong()).build())
        proxy.setPlaybackState(PlaybackState.Builder().setActions(flags).setState(
            if (isPlaying) PlaybackState.STATE_PLAYING else PlaybackState.STATE_PAUSED,
            (value.getDouble("position") * 1000).toLong(), if (isPlaying) 1f else 0f, remoteAt).build())
        proxy.isActive = true
        val signature = listOf(value.getString("id"), value.getString("title"), value.getString("artist"), isPlaying, names).toString()
        if (signature == notificationSignature) return
        val builder = Notification.Builder(context, CHANNEL).setSmallIcon(android.R.drawable.ic_media_play)
            .setContentTitle(value.getString("title")).setContentText(value.getString("artist") + " · Apple Music on Mac")
            .setOnlyAlertOnce(true).setVisibility(Notification.VISIBILITY_PUBLIC)
        val controls = listOf("previous", if (isPlaying) "pause" else "play", "next").filter { it in names }
        for (action in controls) {
            val icon = when (action) { "previous" -> android.R.drawable.ic_media_previous; "next" -> android.R.drawable.ic_media_next; "pause" -> android.R.drawable.ic_media_pause; else -> android.R.drawable.ic_media_play }
            val intent = Intent(context, MediaControlReceiver::class.java).setAction(action).putExtra("id", value.getString("id"))
            val pending = PendingIntent.getBroadcast(context, action.hashCode(), intent, PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE)
            builder.addAction(Notification.Action.Builder(android.graphics.drawable.Icon.createWithResource(context, icon), action, pending).build())
        }
        builder.setStyle(Notification.MediaStyle().setMediaSession(proxy.sessionToken)
            .setShowActionsInCompactView(*controls.indices.toList().toIntArray()))
        runCatching { notifications.notify(NOTIFICATION, builder.build()) }
            .onSuccess { notificationSignature = signature }
    }
    override fun close() {
        closed = true
        handler.removeCallbacksAndMessages(null)
        remote = null; local = null
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
