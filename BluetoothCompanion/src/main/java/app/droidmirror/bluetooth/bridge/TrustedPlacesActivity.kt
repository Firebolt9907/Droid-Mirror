package app.droidmirror.bluetooth.bridge

import android.Manifest
import android.app.Activity
import android.app.AlertDialog
import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.os.SystemClock
import android.provider.Settings
import android.text.InputType
import android.widget.*
import app.droidmirror.bluetooth.TrustedPlacePolicy
import com.google.android.gms.location.CurrentLocationRequest
import com.google.android.gms.location.LocationServices
import com.google.android.gms.location.Priority
import com.google.android.gms.tasks.CancellationTokenSource

class TrustedPlacesActivity : Activity() {
    private lateinit var status: TextView
    private lateinit var list: LinearLayout
    private lateinit var enabled: Switch
    private lateinit var addPlace: Button
    private fun dp(value: Int) = (value * resources.displayMetrics.density).toInt()
    private var locating: CancellationTokenSource? = null
    private val handler = android.os.Handler(android.os.Looper.getMainLooper())
    private val update = object : Runnable {
        override fun run() {
            if (::status.isInitialized && locating == null) status.text = TrustedPlaces.summary(this@TrustedPlacesActivity)
            handler.postDelayed(this, 1000)
        }
    }
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        title = "Trusted places"
        val content = LinearLayout(this).apply { orientation = LinearLayout.VERTICAL; setPadding(dp(24), dp(24), dp(24), dp(24)) }
        enabled = Switch(this).apply {
            text = "Pause Mac detection at trusted places"
            isChecked = TrustedPlaces.enabled(this@TrustedPlacesActivity)
            setOnCheckedChangeListener { _, value -> TrustedPlaces.setEnabled(this@TrustedPlacesActivity, value); refresh() }
        }
        content.addView(enabled)
        content.addView(TextView(this).apply {
            text = "Save places such as Home while you are there. Detection pauses and reminders clear inside any saved circle. To work with your screen locked, allow precise location all the time. Android geofence updates can take a few minutes; indoor accuracy varies. DroidMirror stores saved places locally. If location or geofencing is unavailable, normal detection continues."
        })
        status = TextView(this).apply { setTextIsSelectable(true) }; content.addView(status)
        fun button(label: String, action: () -> Unit) { content.addView(Button(this).apply { text = label; setOnClickListener { action() } }) }
        addPlace = Button(this).apply { text = "Add current location"; setOnClickListener { addCurrent() } }
        content.addView(addPlace)
        button("Allow background location") {
            if (!TrustedPlaces.foregroundAllowed(this)) requestFine()
            else if (Build.VERSION.SDK_INT == 29) requestPermissions(arrayOf(Manifest.permission.ACCESS_BACKGROUND_LOCATION), 202)
            else AlertDialog.Builder(this).setTitle("Allow location all the time")
                .setMessage("Open Permissions → Location, choose Allow all the time, and enable precise location. This lets trusted places pause detection while the app is in the background.")
                .setPositiveButton("Open app settings") { _, _ -> startActivity(Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS, Uri.parse("package:$packageName"))) }
                .setNegativeButton("Cancel", null).show()
        }
        button("Android location settings") { startActivity(Intent(Settings.ACTION_LOCATION_SOURCE_SETTINGS)) }
        button("Retry trusted place monitoring") { TrustedPlaces.ensure(this, true); refresh() }
        list = LinearLayout(this).apply { orientation = LinearLayout.VERTICAL }; content.addView(list)
        setContentView(ScrollView(this).apply { addView(content) })
    }
    override fun onResume() { super.onResume(); TrustedPlaces.ensure(this); refresh(); handler.post(update) }
    override fun onPause() { handler.removeCallbacks(update); super.onPause() }
    private fun refresh() {
        if (!::status.isInitialized) return
        status.text = TrustedPlaces.summary(this)
        addPlace.isEnabled = locating == null
        addPlace.text = if (locating == null) "Add current location" else "Finding location…"
        list.removeAllViews()
        if (TrustedPlaces.places(this).isEmpty()) {
            list.addView(TextView(this).apply { text = "No trusted places yet. Add your current location to get started."; setPadding(0, dp(16), 0, dp(16)) })
        }
        TrustedPlaces.places(this).forEach { place ->
            list.addView(Button(this).apply {
                text = "Remove ${place.name} (${place.radius.toInt()} m)"
                setOnClickListener {
                    AlertDialog.Builder(this@TrustedPlacesActivity).setMessage("Remove ${place.name}?")
                        .setPositiveButton("Remove") { _, _ -> TrustedPlaces.remove(this@TrustedPlacesActivity, place.id); refresh() }
                        .setNegativeButton("Cancel", null).show()
                }
            })
        }
    }
    private fun requestFine() { requestPermissions(arrayOf(Manifest.permission.ACCESS_FINE_LOCATION, Manifest.permission.ACCESS_COARSE_LOCATION), 201) }
    override fun onRequestPermissionsResult(request: Int, permissions: Array<out String>, results: IntArray) {
        super.onRequestPermissionsResult(request, permissions, results)
        TrustedPlaces.ensure(this, true); refresh()
        if (request == 201 && !TrustedPlaces.foregroundAllowed(this)) toast("Trusted places need precise location. You can leave this feature off.")
    }
    private fun toast(message: String) { Toast.makeText(this, message, Toast.LENGTH_LONG).show() }
    private fun addCurrent() {
        if (locating != null) return
        if (!TrustedPlaces.foregroundAllowed(this)) { requestFine(); return }
        if (TrustedPlaces.places(this).size >= 20) { toast("Remove a place before adding another (20 maximum)."); return }
        val form = LinearLayout(this).apply { orientation = LinearLayout.VERTICAL; setPadding(dp(24), dp(16), dp(24), dp(16)) }
        val name = EditText(this).apply { hint = "Name"; setText(if (TrustedPlaces.places(this@TrustedPlacesActivity).isEmpty()) "Home" else "Trusted place") }
        val radius = EditText(this).apply { hint = "Radius in metres (100–5000)"; inputType = InputType.TYPE_CLASS_NUMBER; setText("200") }
        form.addView(name); form.addView(radius)
        val dialog = AlertDialog.Builder(this).setTitle("Save current location").setView(form)
            .setPositiveButton("Save here", null).setNegativeButton("Cancel", null).create()
        dialog.setOnShowListener {
            dialog.getButton(AlertDialog.BUTTON_POSITIVE).setOnClickListener {
                val label = name.text.toString().trim()
                val metres = radius.text.toString().toFloatOrNull()
                if (label.isBlank() || label.length > 80 || metres == null || !TrustedPlacePolicy.valid(0.0, 0.0, metres)) {
                    toast("Enter a name (up to 80 characters) and a radius from 100 to 5000 metres."); return@setOnClickListener
                }
                dialog.dismiss(); locateAndSave(label, metres)
            }
        }
        dialog.show()
    }
    @Suppress("MissingPermission")
    private fun locateAndSave(name: String, radius: Float) {
        locating?.cancel()
        val source = CancellationTokenSource(); locating = source
        refresh()
        status.text = "Finding current location (up to 30 seconds)…"
        val request = CurrentLocationRequest.Builder().setPriority(Priority.PRIORITY_HIGH_ACCURACY)
            .setDurationMillis(30_000).setMaxUpdateAgeMillis(60_000).build()
        try {
            LocationServices.getFusedLocationProviderClient(this).getCurrentLocation(request, source.token)
                .addOnSuccessListener { location ->
                    if (isDestroyed || locating !== source) return@addOnSuccessListener
                    locating = null
                    if (location == null || !location.hasAccuracy() || !TrustedPlacePolicy.usableFix(
                            (SystemClock.elapsedRealtimeNanos() - location.elapsedRealtimeNanos) / 1_000_000, location.accuracy, radius)) {
                        refresh(); toast("No fresh, accurate fix. Try outside or choose a larger radius."); return@addOnSuccessListener
                    }
                    TrustedPlaces.add(this, name, location.latitude, location.longitude, radius)
                    TrustedPlaces.setEnabled(this, true); enabled.isChecked = true
                    refresh(); toast("Saved $name. Allow background location to pause detection automatically.")
                }.addOnFailureListener {
                    if (!isDestroyed && locating === source) { locating = null; refresh(); toast("Could not get location. Check permissions and Android Location settings.") }
                }
        } catch (_: SecurityException) { locating = null; refresh(); toast("Location permission is required.") }
    }
    override fun onStop() {
        // Ignore completion after leaving this screen, including cancellation callbacks.
        val source = locating
        locating = null
        source?.cancel()
        super.onStop()
    }
    override fun onDestroy() { handler.removeCallbacks(update); locating?.cancel(); locating = null; super.onDestroy() }
}
