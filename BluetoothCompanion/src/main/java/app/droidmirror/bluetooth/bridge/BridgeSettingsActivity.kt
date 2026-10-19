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
    private val handler = Handler(Looper.getMainLooper())
    private val refreshStatus = object : Runnable {
        override fun run() {
            val runtime = BridgeRuntime.live
            status.text = when {
                runtime != null -> "${runtime.status}\n${runtime.details}"
                BackgroundBridgePreferences.enabled(this@BridgeSettingsActivity) -> "Starting background bridge…"
                else -> "Background bridge stopped"
            }
            handler.postDelayed(this, 1000)
        }
    }
    override fun onCreate(state: Bundle?) {
        super.onCreate(state)
        title = "Notifications and wireless ADB"
        status = TextView(this).apply { text = "Background bridge stopped"; textSize = 18f }
        permissions = TextView(this).apply { setTextIsSelectable(true) }
        val layout = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            setPadding(32, 48, 32, 32)
            addView(TextView(context).apply { text = "DroidMirror notifications and wireless ADB"; textSize = 24f })
            addView(TextView(context).apply {
                text = "Forward phone notifications over encrypted Bluetooth, even when mirroring is closed. Mirroring video tries Iroh on the local network, then wireless ADB, then Bluetooth. Relay servers are disabled. Wireless ADB is optional and is enabled only by the explicit button below. Pair once with your Mac for mirroring and notifications. One background bridge keeps mirroring, discovery and notification forwarding ready. The Pair Mac button below opens the shared pairing screen.\n\nStop the old BLE ADB Bridge before enabling this service. Use DroidMirror’s shared pairing code and allow its notification access."
            })
            addView(status)
            addView(permissions)
        }
        fun button(label: String, action: () -> Unit) {
            layout.addView(Button(this).apply { text = label; setOnClickListener { action() } })
        }
        button("Enable background bridge") {
            if (hasBluetoothPermissions()) startBridge() else requestPermissions(
                arrayOf(Manifest.permission.BLUETOOTH_CONNECT, Manifest.permission.BLUETOOTH_ADVERTISE), 100)
        }
        button("Pair Mac (mirroring and notifications)") {
            startActivity(Intent(this, app.droidmirror.bluetooth.CaptureActivity::class.java).putExtra("pairMac", true))
        }
        button("Allow notification forwarding") { startActivity(Intent(Settings.ACTION_NOTIFICATION_LISTENER_SETTINGS)) }
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
        button("Stop background bridge") {
            BackgroundBridgePreferences.setEnabled(this, false)
            stopService(Intent(this, CaptureService::class.java))
            status.text = "Background bridge stopped"
        }
        setContentView(ScrollView(this).apply { addView(layout) })
    }
    private fun hasBluetoothPermissions(): Boolean = Build.VERSION.SDK_INT < 31 ||
        (checkSelfPermission(Manifest.permission.BLUETOOTH_CONNECT) == PackageManager.PERMISSION_GRANTED &&
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
        permissions.text = "\nNotification forwarding: ${if (access) "allowed" else "not allowed"}\n" +
            "Shared Mac pairing code: ${if (BleTrust.key(this) != null) "available; paste it on your Mac" else "select a Mac and tap Pair Mac"}\n" +
            (if (secure) "Optional wireless ADB setup: authorized\n" else
                "Start and authorize Shizuku in the main setup screen. DroidMirror grants secure settings automatically, or tap Grant secure settings with Shizuku to retry.\n") +
            grantMessage
    }
    override fun onRequestPermissionsResult(request: Int, permissions: Array<out String>, grants: IntArray) {
        super.onRequestPermissionsResult(request, permissions, grants)
        if (request == 100 && hasBluetoothPermissions()) startBridge()
        else status.text = "Nearby Devices permission is required."
    }
    override fun onPause() {
        handler.removeCallbacks(refreshStatus)
        super.onPause()
    }
}
