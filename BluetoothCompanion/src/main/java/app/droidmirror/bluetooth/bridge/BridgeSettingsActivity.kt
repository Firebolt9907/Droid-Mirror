package app.droidmirror.bluetooth.bridge

import app.droidmirror.bluetooth.CaptureService
import app.droidmirror.bluetooth.BackgroundBridgePreferences
import app.droidmirror.bluetooth.SecureSettingsPermission

import android.Manifest
import android.app.Activity
import android.app.NotificationManager
import android.content.*
import android.content.pm.PackageManager
import android.os.*
import android.provider.Settings
import android.widget.*

/** Setup for discovery and notifications sharing the mirroring background service. */
class BridgeSettingsActivity : Activity() {
    private lateinit var status: TextView
    private lateinit var permissions: TextView
    private var grantMessage = ""
    private var requestedDetectionPermissions = false
    private lateinit var experimentStats: TextView
    private val handler = Handler(Looper.getMainLooper())
    private val refreshStatus = object : Runnable {
        override fun run() {
            val runtime = BridgeRuntime.live
            status.text = when {
                runtime != null -> "${runtime.status}\n${runtime.details}\n${WearPhoneBridge.batterySummary()}"
                BackgroundBridgePreferences.enabled(this@BridgeSettingsActivity) -> "Starting background bridge…"
                else -> "Background bridge stopped"
            }
            updatePermissionState()
            if (::experimentStats.isInitialized) experimentStats.text = LeftBehindMonitor.stats(this@BridgeSettingsActivity)
            handler.postDelayed(this, 1000)
        }
    }
    override fun onCreate(state: Bundle?) {
        super.onCreate(state)
        title = "Background features and setup"
        status = TextView(this).apply { text = "Background bridge stopped"; textSize = 18f }
        permissions = TextView(this).apply { setTextIsSelectable(true) }
        val layout = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            setPadding(32, 48, 32, 32)
            addView(TextView(context).apply { text = "DroidMirror background features"; textSize = 24f })
            addView(TextView(context).apply {
                text = "Notification forwarding has its own permission and Bluetooth connection. Working mirroring does not confirm that forwarding is ready. Complete the steps below, then send a new message to your phone to test."
            })
            addView(status)
            addView(permissions)
        }
        fun button(label: String, action: () -> Unit) {
            layout.addView(Button(this).apply { text = label; setOnClickListener { action() } })
        }
        fun heading(label: String) {
            layout.addView(TextView(this).apply {
                text = label; textSize = 20f; setPadding(0, 32, 0, 8)
            })
        }
        heading("Phone notification setup")
        button("1. Enable background bridge / allow Nearby devices") {
            if (hasBluetoothPermissions()) startBridge() else requestPermissions(
                arrayOf(Manifest.permission.BLUETOOTH_CONNECT, Manifest.permission.BLUETOOTH_ADVERTISE, Manifest.permission.BLUETOOTH_SCAN), 100)
        }
        button("2. Pair Mac (mirroring and notifications)") {
            startActivity(Intent(this, app.droidmirror.bluetooth.CaptureActivity::class.java).putExtra("pairMac", true))
        }
        button("3. Open notification access — enable DroidMirror") {
            startActivity(Intent(Settings.ACTION_NOTIFICATION_LISTENER_SETTINGS))
        }
        layout.addView(TextView(this).apply {
            text = "On the notification access screen, select DroidMirror and turn on Allow notification access. Opening that screen alone does not grant access. This is separate from allowing DroidMirror to post its own status or left-behind notifications. If Android blocks the switch for an installed APK, open Android App info for DroidMirror and allow restricted settings if offered, then return here."
        })
        button("Reconnect notification listener") {
            android.service.notification.NotificationListenerService.requestRebind(ComponentName(this, PhoneNotifications::class.java))
            updatePermissionState()
        }
        layout.addView(TextView(this).apply {
            text = "If access is allowed but the listener stays disconnected, turn DroidMirror notification access off and on again. On your Mac, keep DroidMirror running and allow notifications for DroidMirror Notifications in System Settings → Notifications. Enable the phone app in DroidMirror Settings → Notifications. Test with a new incoming message; existing or silent notifications may appear only in Notification Center. Focus can silence banners. Shizuku and wireless debugging are not required to read and forward notifications."
        })
        heading("Left-behind alerts (optional)")
        layout.addView(Switch(this).apply {
            text = "Mac left-behind alerts"
            isChecked = LeftBehindMonitor.enabled(this@BridgeSettingsActivity)
            isEnabled = LeftBehindMonitor.supported(this@BridgeSettingsActivity)
            setOnCheckedChangeListener { _, enabled ->
                LeftBehindMonitor.setEnabled(this@BridgeSettingsActivity, enabled)
                if (enabled) requestDetectionPermissions()
            }
        })
        layout.addView(TextView(this).apply {
            text = if (LeftBehindMonitor.supported(this@BridgeSettingsActivity))
                "Uses the selected Mac Bluetooth beacon detector (formerly #2). Requires the background bridge and the paired Mac running DroidMirror. After first detecting the beacon nearby, recent movement and two failed scans can produce a reminder. Sleep, Bluetooth settings and interference can still cause false alerts."
            else "Left-behind alerts are unavailable: this phone has no significant-motion sensor."
        })
        layout.addView(Switch(this).apply {
            text = "Show left-behind reminders"
            isChecked = LeftBehindMonitor.alertsEnabled(this@BridgeSettingsActivity, LeftBehindMonitor.ALGORITHM)
            setOnCheckedChangeListener { _, enabled -> LeftBehindMonitor.setAlertsEnabled(this@BridgeSettingsActivity, LeftBehindMonitor.ALGORITHM, enabled) }
        })
        layout.addView(Switch(this).apply {
            text = "Use Live Activity until Mac returns"
            isChecked = LeftBehindMonitor.temporary(this@BridgeSettingsActivity)
            setOnCheckedChangeListener { _, enabled -> LeftBehindMonitor.setTemporary(this@BridgeSettingsActivity, enabled) }
        })
        layout.addView(TextView(this).apply {
            text = "Off: a normal notification. On: an ongoing Live Activity. Both go away when the Mac beacon is detected again or you tap Dismiss. There is no timer. Android controls Live Activity promotion; older versions show an ongoing notification with the same behavior. This setting applies to the next reminder. Historical experiment records are retained below."
        })
        experimentStats = TextView(this).apply {
            text = LeftBehindMonitor.stats(this@BridgeSettingsActivity)
            setTextIsSelectable(true)
        }
        layout.addView(experimentStats)
        button("Allow detection permissions") {
            requestedDetectionPermissions = false
            requestDetectionPermissions()
        }
        button("Refresh left-behind counts") { experimentStats.text = LeftBehindMonitor.stats(this) }
        button("Reset left-behind counts") {
            LeftBehindMonitor.resetStats(this)
            experimentStats.text = LeftBehindMonitor.stats(this)
        }
        heading("Wireless ADB and Shizuku (optional for notifications)")
        button("Grant secure settings with Shizuku") {
            SecureSettingsPermission.ensure(this) { message ->
                grantMessage = message
                updatePermissionState()
                if (SecureSettingsPermission.granted(this)) BridgeRuntime.live?.findEndpoint()
            }
        }
        button("Set up Shizuku") { startActivity(Intent(this, app.droidmirror.bluetooth.CaptureActivity::class.java)) }
        button("Wireless debugging settings") { startActivity(Intent(Settings.ACTION_APPLICATION_DEVELOPMENT_SETTINGS)) }
        button("Enable wireless ADB (optional)") {
            BridgeRuntime.live?.findEndpoint(enableWirelessDebugging = true) ?: run { status.text = "Enable the background bridge first." }
        }
        heading("Recovery")
        button("Stop background bridge (also stops forwarding)") {
            BackgroundBridgePreferences.setEnabled(this, false)
            stopService(Intent(this, CaptureService::class.java))
            status.text = "Background bridge stopped"
        }
        setContentView(ScrollView(this).apply { addView(layout) })
    }
    private fun requestDetectionPermissions() {
        if (requestedDetectionPermissions) return
        val needed = mutableListOf<String>()
        if (Build.VERSION.SDK_INT >= 33) needed.add(Manifest.permission.POST_NOTIFICATIONS)
        if (Build.VERSION.SDK_INT >= 31) needed.addAll(listOf(Manifest.permission.BLUETOOTH_SCAN,
            Manifest.permission.BLUETOOTH_CONNECT, Manifest.permission.BLUETOOTH_ADVERTISE))
        else needed.add(Manifest.permission.ACCESS_FINE_LOCATION)
        val missing = needed.filter { checkSelfPermission(it) != PackageManager.PERMISSION_GRANTED }
        if (missing.isNotEmpty()) {
            requestedDetectionPermissions = true
            requestPermissions(missing.toTypedArray(), 101)
        }
    }
    private fun hasBluetoothPermissions(): Boolean = Build.VERSION.SDK_INT < 31 ||
        (checkSelfPermission(Manifest.permission.BLUETOOTH_SCAN) == PackageManager.PERMISSION_GRANTED &&
         checkSelfPermission(Manifest.permission.BLUETOOTH_CONNECT) == PackageManager.PERMISSION_GRANTED &&
         checkSelfPermission(Manifest.permission.BLUETOOTH_ADVERTISE) == PackageManager.PERMISSION_GRANTED)
    private fun startBridge() {
        BackgroundBridgePreferences.setEnabled(this, true)
        val result = CaptureService.enableIfConfigured(this)
        if (result != CaptureService.ReadyResult.START_REQUESTED)
            status.text = "Could not start bridge: $result"
    }
    override fun onResume() {
        super.onResume()
        CaptureService.enableIfConfigured(this)
        handler.removeCallbacks(refreshStatus)
        handler.post(refreshStatus)
        updatePermissionState()
        if (LeftBehindMonitor.enabled(this)) requestDetectionPermissions()
        if (!SecureSettingsPermission.granted(this) && SecureSettingsPermission.shizukuAuthorized()) {
            SecureSettingsPermission.ensure(this) { message ->
                grantMessage = message
                updatePermissionState()
                if (SecureSettingsPermission.granted(this)) BridgeRuntime.live?.findEndpoint()
            }
        }
    }
    private fun updatePermissionState() {
        val component = ComponentName(this, PhoneNotifications::class.java)
        val access = if (Build.VERSION.SDK_INT >= 27)
            getSystemService(NotificationManager::class.java).isNotificationListenerAccessGranted(component)
        else Settings.Secure.getString(contentResolver, "enabled_notification_listeners")
            .orEmpty().split(':').any { ComponentName.unflattenFromString(it) == component }
        val secure = checkSelfPermission(Manifest.permission.WRITE_SECURE_SETTINGS) == PackageManager.PERMISSION_GRANTED
        permissions.text = "\nLeft-behind alerts: ${if (LeftBehindMonitor.enabled(this)) (if (getSystemService(NotificationManager::class.java).areNotificationsEnabled()) "enabled (experimental)" else "allow DroidMirror notifications in Android settings") else "off"}\n" +
            "Bluetooth scan permission: ${if (Build.VERSION.SDK_INT < 31 || checkSelfPermission(Manifest.permission.BLUETOOTH_SCAN) == PackageManager.PERMISSION_GRANTED) "allowed" else "missing — Mac beacon scanning cannot run"}\n" +
            "Bluetooth connect permission: ${if (Build.VERSION.SDK_INT < 31 || checkSelfPermission(Manifest.permission.BLUETOOTH_CONNECT) == PackageManager.PERMISSION_GRANTED) "allowed" else "missing — background Bluetooth features may be unavailable"}\n" +
            "Notification access: ${if (access) "allowed" else "missing — complete step 3"}\n" +
            "Notification listener: ${if (PhoneNotifications.live != null) "connected" else if (access) "disconnected — try reconnecting below" else "waiting for access"}\n" +
            "Shared Mac pairing code: ${if (BleTrust.key(this) != null) "available (does not confirm Mac connection)" else "select a Mac and tap Pair Mac"}\n" +
            (if (secure) "Optional wireless ADB setup: authorized\n" else
                "Start and authorize Shizuku in the main setup screen. DroidMirror grants secure settings automatically, or tap Grant secure settings with Shizuku to retry.\n") +
            grantMessage
    }
    override fun onRequestPermissionsResult(request: Int, permissions: Array<out String>, grants: IntArray) {
        super.onRequestPermissionsResult(request, permissions, grants)
        if (request == 101) {
            if (grants.isEmpty() || grants.any { it != PackageManager.PERMISSION_GRANTED })
                status.text = "Allow Nearby Devices and notifications (Location on Android 11 or earlier) for all left-behind channels."
            BridgeRuntime.live?.refreshLeftBehind()
            updatePermissionState()
            return
        }
        if (request == 100 && hasBluetoothPermissions()) startBridge()
        else status.text = "Nearby Devices permission is required."
    }
    override fun onPause() {
        handler.removeCallbacks(refreshStatus)
        super.onPause()
    }
}
