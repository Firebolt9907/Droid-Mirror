package app.droidmirror.bluetooth.bridge

import android.app.NotificationManager
import android.content.*
import android.os.Build
import org.json.JSONObject

/** Runs on BridgeRuntime's handler; never uses shell privileges or bypasses policy access. */
class PhoneFocusSync(private val context: Context) : AutoCloseable {
    private val manager = context.getSystemService(NotificationManager::class.java)
    private val preferences = context.getSharedPreferences("focus_sync", Context.MODE_PRIVATE)
    private var expected: Int? = null
    private var origin = ""
    private var deadline = 0L
    private fun reconcile() {
        if (expected != null && manager.currentInterruptionFilter != expected && android.os.SystemClock.elapsedRealtime() >= deadline) { expected = null; origin = "" }
    }
    private val receiver = object : BroadcastReceiver() {
        override fun onReceive(context: Context?, intent: Intent?) {
            if (manager.currentInterruptionFilter == expected) deadline = 0L
            reconcile()
        }
    }
    init {
        val filter = IntentFilter(NotificationManager.ACTION_INTERRUPTION_FILTER_CHANGED)
        if (Build.VERSION.SDK_INT >= 33) context.registerReceiver(receiver, filter, Context.RECEIVER_EXPORTED)
        else context.registerReceiver(receiver, filter)
    }
    fun receive(command: JSONObject): JSONObject {
        var error = ""
        if (command.optString("type") == "focusSet") {
            if (!preferences.getBoolean("macToPhone", false)) error = "disabled"
            else if (!manager.isNotificationPolicyAccessGranted) error = "policyAccessRequired"
            else if (command.opt("focused") !is Boolean || command.opt("origin") !is String || command.optString("origin").length !in 1..64) error = "invalid"
            else {
                val target = if (command.getBoolean("focused")) NotificationManager.INTERRUPTION_FILTER_PRIORITY else NotificationManager.INTERRUPTION_FILTER_ALL
                try {
                    expected = target; origin = command.getString("origin"); deadline = android.os.SystemClock.elapsedRealtime() + 5000
                    manager.setInterruptionFilter(target)
                } catch (_: SecurityException) { expected = null; origin = ""; error = "policyAccessRequired" }
            }
        }
        val filter = manager.currentInterruptionFilter
        if (filter == expected) deadline = 0L
        reconcile()
        return JSONObject().put("type", "focusState")
            .put("available", (expected == null || filter == expected) && preferences.getBoolean("phoneToMac", false) && manager.isNotificationPolicyAccessGranted && filter != NotificationManager.INTERRUPTION_FILTER_UNKNOWN)
            .put("focused", filter != NotificationManager.INTERRUPTION_FILTER_ALL)
            .put("canSet", preferences.getBoolean("macToPhone", false) && manager.isNotificationPolicyAccessGranted)
            .put("filter", filter).put("origin", origin).put("error", error)
    }
    override fun close() { context.unregisterReceiver(receiver) }
}
