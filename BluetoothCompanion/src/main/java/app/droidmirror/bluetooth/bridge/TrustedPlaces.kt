package app.droidmirror.bluetooth.bridge

import android.Manifest
import android.app.PendingIntent
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.location.LocationManager
import android.os.Build
import android.provider.Settings
import com.google.android.gms.location.*
import app.droidmirror.bluetooth.TrustedPlacePolicy
import org.json.JSONArray
import org.json.JSONObject
import java.util.UUID

/** Optional, local-only circles. Play services delivers background enter/exit events. */
object TrustedPlaces {
    data class Place(val id: String, val name: String, val latitude: Double, val longitude: Double, val radius: Float)
    private fun prefs(context: Context) = context.getSharedPreferences("trusted-places", Context.MODE_PRIVATE)
    fun enabled(context: Context) = prefs(context).getBoolean("enabled", false)
    fun places(context: Context): List<Place> = runCatching {
        val array = JSONArray(prefs(context).getString("places", "[]"))
        (0 until array.length()).mapNotNull {
            val p = array.getJSONObject(it)
            val lat = p.getDouble("lat"); val lon = p.getDouble("lon"); val radius = p.getDouble("radius").toFloat()
            if (!TrustedPlacePolicy.valid(lat, lon, radius)) null
            else Place(p.getString("id"), p.getString("name"), lat, lon, radius)
        }.take(20)
    }.getOrDefault(emptyList())
    fun foregroundAllowed(context: Context) = context.checkSelfPermission(Manifest.permission.ACCESS_FINE_LOCATION) == PackageManager.PERMISSION_GRANTED
    fun backgroundAllowed(context: Context) = foregroundAllowed(context) && (Build.VERSION.SDK_INT < 29 ||
        context.checkSelfPermission(Manifest.permission.ACCESS_BACKGROUND_LOCATION) == PackageManager.PERMISSION_GRANTED)
    private fun locationEnabled(context: Context) = if (Build.VERSION.SDK_INT >= 28)
        context.getSystemService(LocationManager::class.java).isLocationEnabled
        else Settings.Secure.getInt(context.contentResolver, Settings.Secure.LOCATION_MODE, 0) != 0
    private fun intent(context: Context): PendingIntent = PendingIntent.getBroadcast(context, 0,
        Intent(context, TrustedPlacesReceiver::class.java).setAction("app.droidmirror.TRUSTED_PLACE"),
        PendingIntent.FLAG_UPDATE_CURRENT or if (Build.VERSION.SDK_INT >= 31) PendingIntent.FLAG_MUTABLE else 0)
    private var signature: String? = null
    private var generation = 0
    private var syncing = false
    private var resync = false
    fun setEnabled(context: Context, enabled: Boolean) {
        prefs(context).edit().putBoolean("enabled", enabled).apply(); ensure(context, true)
    }
    private fun save(context: Context, values: List<Place>) {
        val array = JSONArray()
        values.forEach { array.put(JSONObject().put("id", it.id).put("name", it.name).put("lat", it.latitude).put("lon", it.longitude).put("radius", it.radius.toDouble())) }
        prefs(context).edit().putString("places", array.toString()).apply()
        ensure(context, true)
    }
    fun add(context: Context, name: String, lat: Double, lon: Double, radius: Float) {
        require(name.isNotBlank() && name.length <= 80 && TrustedPlacePolicy.valid(lat, lon, radius))
        val old = places(context); require(old.size < 20)
        val place = Place(UUID.randomUUID().toString(), name.trim(), lat, lon, radius)
        save(context, old + place)
        // add() is called only after a validated fresh fix at this exact centre.
        if (backgroundAllowed(context) && locationEnabled(context)) {
            val inside = prefs(context).getStringSet("inside", emptySet()).orEmpty().toMutableSet().apply { add(place.id) }
            prefs(context).edit().putStringSet("inside", inside)
                .putInt("boot", Settings.Global.getInt(context.contentResolver, Settings.Global.BOOT_COUNT, -1)).apply()
        }
        BridgeRuntime.live?.refreshTrustedPlaces()
    }
    fun remove(context: Context, id: String) { save(context, places(context).filter { it.id != id }) }
    fun pausedAt(context: Context): String? {
        if (!enabled(context) || !backgroundAllowed(context) || !locationEnabled(context)) return null
        if (prefs(context).getInt("boot", -1) != Settings.Global.getInt(context.contentResolver, Settings.Global.BOOT_COUNT, -2)) return null
        val inside = prefs(context).getStringSet("inside", emptySet()).orEmpty()
        return places(context).firstOrNull { it.id in inside }?.name
    }
    fun summary(context: Context): String {
        val status = when {
            !enabled(context) -> "Trusted places off"
            !foregroundAllowed(context) -> "Precise location permission needed"
            !backgroundAllowed(context) -> "Allow location all the time for background trusted places"
            !locationEnabled(context) -> "Turn on Android Location for trusted places"
            places(context).isEmpty() -> "Add a trusted place"
            pausedAt(context) != null -> "Detection paused at ${pausedAt(context)}"
            else -> prefs(context).getString("status", "Checking trusted places").orEmpty()
        }
        return status + "\n" + places(context).joinToString("\n") { "${it.name} · ${it.radius.toInt()} m radius" }
    }
    @Suppress("MissingPermission")
    fun ensure(context: Context, force: Boolean = false, done: () -> Unit = {}) {
        val values = places(context)
        val ready = enabled(context) && backgroundAllowed(context) && locationEnabled(context) && values.isNotEmpty()
        val boot = Settings.Global.getInt(context.contentResolver, Settings.Global.BOOT_COUNT, -1)
        if (!ready) prefs(context).edit().putStringSet("inside", emptySet()).apply()
        val next = "$ready|$boot|${prefs(context).getString("places", "[]")}"
        if (!force && signature == next) { done(); return }
        if (syncing) { signature = null; resync = true; done(); return }
        syncing = true
        signature = next
        fun complete() {
            syncing = false
            done()
            if (resync) { resync = false; signature = null; ensure(context.applicationContext, true) }
        }
        val token = ++generation
        val existing = if (prefs(context).getInt("boot", -2) == boot) prefs(context).getStringSet("inside", emptySet()).orEmpty() else emptySet()
        prefs(context).edit().putInt("boot", boot).putStringSet("inside", existing.intersect(values.map { it.id }.toSet())).apply()
        val client = LocationServices.getGeofencingClient(context.applicationContext)
        // Only one remove/add chain runs at a time, including rapid edits/toggle changes.
        client.removeGeofences(intent(context)).addOnCompleteListener {
            if (token != generation) { complete(); return@addOnCompleteListener }
            if (!ready) {
                prefs(context).edit().putStringSet("inside", emptySet()).apply()
                BridgeRuntime.live?.refreshTrustedPlaces()
                complete()
                return@addOnCompleteListener
            }
            val request = GeofencingRequest.Builder().setInitialTrigger(GeofencingRequest.INITIAL_TRIGGER_ENTER or GeofencingRequest.INITIAL_TRIGGER_EXIT)
                .addGeofences(values.map {
                    Geofence.Builder().setRequestId(it.id).setCircularRegion(it.latitude, it.longitude, it.radius)
                        .setExpirationDuration(Geofence.NEVER_EXPIRE).setNotificationResponsiveness(60_000)
                        .setTransitionTypes(Geofence.GEOFENCE_TRANSITION_ENTER or Geofence.GEOFENCE_TRANSITION_EXIT).build()
                }).build()
            try {
                client.addGeofences(request, intent(context)).addOnSuccessListener {
                    if (token == generation) prefs(context).edit().putString("status", "Trusted places monitored; no known trusted place entered").apply()
                    complete()
                }.addOnFailureListener { error -> failed(context, token, error); complete() }
            } catch (error: Exception) { failed(context, token, error); complete() }
        }
    }
    private fun failed(context: Context, token: Int, error: Exception) {
        if (token != generation) return
        prefs(context).edit().putStringSet("inside", emptySet()).putString("status", "Trusted places unavailable: ${error.javaClass.simpleName}; detection remains enabled").apply()
        // Retry on the next explicit refresh/start, not every 15-second monitor tick.
        BridgeRuntime.live?.refreshTrustedPlaces()
    }
    fun receive(context: Context, intent: Intent) {
        if (intent.action != "app.droidmirror.TRUSTED_PLACE") {
            signature = null; ensure(context, true); return
        }
        val event = GeofencingEvent.fromIntent(intent) ?: return
        if (event.hasError()) { failed(context, generation, IllegalStateException("Geofence error ${event.errorCode}")); return }
        if (!enabled(context) || !backgroundAllowed(context)) return
        val transition = event.geofenceTransition
        if (transition != Geofence.GEOFENCE_TRANSITION_ENTER && transition != Geofence.GEOFENCE_TRANSITION_EXIT) return
        val inside = prefs(context).getStringSet("inside", emptySet()).orEmpty()
        val updated = TrustedPlacePolicy.transition(inside, places(context).map { it.id }.toSet(),
            event.triggeringGeofences.orEmpty().map { it.requestId }.toSet(), transition == Geofence.GEOFENCE_TRANSITION_ENTER)
        prefs(context).edit().putStringSet("inside", updated).apply()
        BridgeRuntime.live?.refreshTrustedPlaces()
    }
}

class TrustedPlacesReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        if (intent.action == "app.droidmirror.TRUSTED_PLACE") TrustedPlaces.receive(context.applicationContext, intent)
        else {
            val pending = goAsync()
            // Keep the reboot/update receiver alive through asynchronous registration.
            val handler = android.os.Handler(android.os.Looper.getMainLooper())
            val finished = java.util.concurrent.atomic.AtomicBoolean(false)
            fun finish() { if (finished.compareAndSet(false, true)) pending.finish() }
            handler.postDelayed({ finish() }, 8_000)
            try { TrustedPlaces.ensure(context.applicationContext, true) { finish() } }
            catch (_: Exception) { finish() }
        }
    }
}
