package app.droidmirror.bluetooth.bridge

import android.app.NotificationManager
import android.app.PendingIntent
import android.content.BroadcastReceiver
import android.content.ContentValues
import android.content.Context
import android.content.Intent
import android.database.sqlite.SQLiteDatabase
import android.database.sqlite.SQLiteOpenHelper
import android.net.Uri
import android.os.SystemClock
import android.provider.Settings
import app.droidmirror.bluetooth.LeftBehindFeedbackEvent
import java.text.DateFormat
import java.util.Date
import java.util.UUID

/** An append-only notification log, separate from resettable radio counters. */
object LeftBehindFeedback {
    private class Database(context: Context) : SQLiteOpenHelper(context.applicationContext, "left-behind-feedback.db", null, 1) {
        override fun onCreate(db: SQLiteDatabase) {
            db.execSQL("""CREATE TABLE events(id TEXT PRIMARY KEY, algorithm INTEGER NOT NULL,
                posted_wall INTEGER NOT NULL, started INTEGER NOT NULL, boot INTEGER NOT NULL,
                outcome TEXT NOT NULL, duration INTEGER, reason TEXT, detail TEXT NOT NULL,
                last_seen INTEGER NOT NULL)""")
            db.execSQL("CREATE INDEX pending_events ON events(algorithm,outcome,duration)")
            db.execSQL("CREATE INDEX recent_events ON events(posted_wall)")
        }
        override fun onUpgrade(db: SQLiteDatabase, old: Int, new: Int) {}
    }
    private var helper: Database? = null
    @Synchronized private fun db(context: Context): SQLiteDatabase {
        if (helper == null) helper = Database(context)
        return helper!!.writableDatabase
    }
    private fun boot(context: Context) = Settings.Global.getInt(context.contentResolver, Settings.Global.BOOT_COUNT, -1)
    fun create(context: Context, index: Int, detail: String): String {
        val id = UUID.randomUUID().toString()
        val now = SystemClock.elapsedRealtime()
        db(context).insertOrThrow("events", null, ContentValues().apply {
            put("id", id); put("algorithm", index + 1); put("posted_wall", System.currentTimeMillis())
            put("started", now); put("boot", boot(context)); put("outcome", "posting"); put("detail", detail); put("last_seen", now)
        })
        return id
    }
    fun posted(context: Context, id: String, index: Int) {
        val database = db(context)
        database.beginTransaction()
        try {
            finishAlgorithm(context, index, "replaced")
            database.update("events", ContentValues().apply { put("outcome", "unanswered") }, "id=? AND outcome='posting'", arrayOf(id))
            database.setTransactionSuccessful()
        } finally { database.endTransaction() }
    }
    fun discard(context: Context, id: String) { db(context).delete("events", "id=? AND outcome='posting'", arrayOf(id)) }
    private fun finish(context: Context, id: String, outcome: String, reason: String, observed: Long? = null): Boolean {
        val database = db(context)
        database.query("events", arrayOf("started", "boot"), "id=? AND outcome='unanswered' AND duration IS NULL", arrayOf(id), null, null, null).use { row ->
            if (!row.moveToFirst()) return false
            val elapsed = LeftBehindFeedbackEvent.elapsed(row.getLong(0), row.getInt(1), observed ?: SystemClock.elapsedRealtime(), boot(context))
            return database.update("events", ContentValues().apply {
                put("outcome", outcome); put("duration", elapsed); put("reason", reason)
            }, "id=? AND outcome='unanswered' AND duration IS NULL", arrayOf(id)) == 1
        }
    }
    fun finishAlgorithm(context: Context, index: Int, reason: String) {
        val ids = mutableListOf<String>()
        db(context).query("events", arrayOf("id"), "algorithm=? AND outcome='unanswered' AND duration IS NULL", arrayOf((index + 1).toString()), null, null, null).use { rows ->
            while (rows.moveToNext()) ids.add(rows.getString(0))
        }
        ids.forEach { finish(context, it, "unanswered", reason) }
    }
    fun action(context: Context, id: String, action: String) {
        if (action != "dismissed" && !LeftBehindFeedbackEvent.choice(action)) return
        val changed = finish(context, id, if (action == "dismissed") "unanswered" else action, action)
        if (!changed) return
        // A stale action must never cancel a newer notification for the same algorithm.
        context.getSystemService(NotificationManager::class.java).activeNotifications.firstOrNull {
            it.notification.extras.getString("leftBehindEvent") == id
        }?.let { context.getSystemService(NotificationManager::class.java).cancel(it.id) }
    }
    fun intent(context: Context, id: String, action: String): PendingIntent = PendingIntent.getBroadcast(context, 0,
        Intent(context, LeftBehindFeedbackReceiver::class.java).setAction(action)
            .setData(Uri.parse("droidmirror-feedback://event/$id/$action")).putExtra("event", id),
        PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE)

    /** Reconcile OS removals missed while the process was stopped. Never invent a removal time. */
    fun reconcile(context: Context) {
        val active = context.getSystemService(NotificationManager::class.java).activeNotifications
            .mapNotNull { it.notification.extras.getString("leftBehindEvent") }.toSet()
        val pending = mutableListOf<Triple<String, Long, Int>>()
        db(context).query("events", arrayOf("id", "last_seen", "boot"), "outcome='unanswered' AND duration IS NULL", null, null, null, null).use { rows ->
            while (rows.moveToNext()) pending.add(Triple(rows.getString(0), rows.getLong(1), rows.getInt(2)))
        }
        pending.forEach { (id, last, startBoot) ->
            if (id in active && startBoot == boot(context)) {
                db(context).update("events", ContentValues().apply { put("last_seen", SystemClock.elapsedRealtime()) }, "id=?", arrayOf(id))
            } else {
                finish(context, id, "unanswered", "removal time unknown; last observed lifetime only", if (startBoot == boot(context)) last else -1)
            }
        }
        // A process killed between create and posted has no reliable posting record.
        db(context).delete("events", "outcome='posting' AND posted_wall<?", arrayOf((System.currentTimeMillis() - 60_000).toString()))
    }
    fun summary(context: Context): String {
        val database = db(context)
        val lines = mutableListOf("Reminder history (including archived experiment decisions; retained separately from counter resets):")
        database.rawQuery("SELECT algorithm,outcome,COUNT(*) FROM events WHERE outcome!='posting' GROUP BY algorithm,outcome ORDER BY algorithm,outcome", null).use { rows ->
            while (rows.moveToNext()) lines.add("#${rows.getInt(0)} ${rows.getString(1)}: ${rows.getLong(2)}")
        }
        lines.add("Recent decisions / unanswered lifetimes:")
        database.rawQuery("SELECT algorithm,posted_wall,outcome,duration,reason,started,boot FROM events WHERE outcome!='posting' ORDER BY posted_wall DESC,rowid DESC LIMIT 40", null).use { rows ->
            while (rows.moveToNext()) {
                val open = rows.isNull(3)
                val ms = if (open) LeftBehindFeedbackEvent.elapsed(rows.getLong(5), rows.getInt(6), SystemClock.elapsedRealtime(), boot(context)) else rows.getLong(3)
                val time = DateFormat.getDateTimeInstance(DateFormat.SHORT, DateFormat.MEDIUM).format(Date(rows.getLong(1)))
                lines.add("$time #${rows.getInt(0)} ${rows.getString(2)} (${LeftBehindFeedbackEvent.duration(ms)}${if (open) "; still posted, last checked by bridge" else "; ${rows.getString(4)}"})")
            }
        }
        return lines.joinToString("\n")
    }
}

class LeftBehindFeedbackReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        val id = intent.getStringExtra("event") ?: return
        LeftBehindFeedback.action(context, id, intent.action ?: return)
    }
}
