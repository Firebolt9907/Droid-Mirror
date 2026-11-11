package app.droidmirror.bluetooth.bridge

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.os.SystemClock
import org.json.JSONObject

/** One ongoing notification for an actual clipboard file operation, never for an idle connection. */
class ClipboardSyncActivity(private val context: Context) {
    companion object { const val ID = 7307; const val CHANNEL = "clipboard-file-sync" }
    private val main = Handler(Looper.getMainLooper())
    private val notifications = context.getSystemService(NotificationManager::class.java)
    private val state = ClipboardSyncProgress()
    private var postedTag: String? = null
    private var lastPosted = 0L
    private var lastDisplay = ""
    private val update = Runnable { publish() }
    init {
        notifications.cancel(ID) // clean up the old untagged implementation
        notifications.activeNotifications.filter { it.id == ID && it.tag?.startsWith("clipboard-sync/") == true }
            .forEach { notifications.cancel(it.tag, ID) }
    }
    fun observe(event: JSONObject, sent: Boolean) {
        val previous = state.current?.token
        state.observe(event, sent)
        if (state.current == null) { clear(); return }
        if (previous != state.current?.token) { main.removeCallbacks(update); lastDisplay = ""; publish() }
        else {
            main.removeCallbacks(update)
            val delay = maxOf(0L, 250 - (SystemClock.elapsedRealtime() - lastPosted))
            main.postDelayed(update, delay)
        }
    }
    fun isPreparing(id: String) = state.current?.let { it.id == id && it.preparing } == true
    fun matches(id: String, token: String) = state.matches(id, token)
    private fun publish() {
        val transfer = state.current ?: return
        val percent = if (transfer.size == 0) 0 else minOf(99, transfer.bytes * 100 / transfer.size)
        val display = "${transfer.token}:${transfer.preparing}:$percent"
        if (display == lastDisplay) return
        val tag = "clipboard-sync/${transfer.token}"
        // Each file is a new Live Activity. Reuse its key only for its own progress,
        // never a key Android may retain as dismissed from an earlier operation.
        if (postedTag != tag) {
            postedTag?.let { notifications.cancel(it, ID) }
            lastPosted = 0L
        }
        val cancel = PendingIntent.getBroadcast(context, 0,
            Intent(context, ClipboardSyncActionReceiver::class.java)
                .setAction("app.droidmirror.bluetooth.CANCEL_CLIPBOARD_FILE")
                .setData(Uri.parse("droidmirror://clipboard-sync/${transfer.token}"))
                .putExtra("id", transfer.id).putExtra("token", transfer.token),
            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT)
        val direction = if (transfer.sending) "Uploading" else "Downloading"
        val title = if (transfer.preparing) "Preparing ${if (transfer.sending) "upload" else "download"}"
            else "$direction · $percent%"
        val builder = Notification.Builder(context, CHANNEL)
            .setSmallIcon(if (transfer.sending) android.R.drawable.stat_sys_upload else android.R.drawable.stat_sys_download)
            .setContentTitle(title)
            .setContentText(if (transfer.sending) "Clipboard file to Mac" else "Clipboard file from Mac")
            .setCategory(Notification.CATEGORY_STATUS).setOngoing(true).setOnlyAlertOnce(true)
            .setShowWhen(false).setTimeoutAfter(65_000).setVisibility(Notification.VISIBILITY_PRIVATE)
            .setProgress(100, percent, transfer.preparing || transfer.size == 0)
            .addAction(Notification.Action.Builder(null, "Cancel", cancel).build())
        if (Build.VERSION.SDK_INT >= 36) {
            builder.setShortCriticalText(if (transfer.preparing) "Preparing" else "$percent%")
            builder.addExtras(Bundle().apply { putBoolean("android.requestPromotedOngoing", true) })
        }
        notifications.createNotificationChannel(NotificationChannel(CHANNEL, "Clipboard file syncing", NotificationManager.IMPORTANCE_LOW))
        try {
            notifications.notify(tag, ID, builder.build())
            if (postedTag != tag) android.util.Log.i("DroidMirrorClipboard", "File activity started id=${transfer.id} sending=${transfer.sending}")
            postedTag = tag; lastPosted = SystemClock.elapsedRealtime(); lastDisplay = display
        }
        catch (_: SecurityException) { /* Notification permission may be disabled; sync still works. */ }
    }
    fun clear() {
        main.removeCallbacks(update); state.clear(); lastDisplay = ""
        postedTag?.let {
            notifications.cancel(it, ID)
            android.util.Log.i("DroidMirrorClipboard", "File activity ended")
        }
        postedTag = null
    }
}

class ClipboardSyncActionReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        if (intent.action != "app.droidmirror.bluetooth.CANCEL_CLIPBOARD_FILE") return
        BridgeRuntime.live?.cancelClipboardSync(intent.getStringExtra("id") ?: return, intent.getStringExtra("token") ?: return)
    }
}
