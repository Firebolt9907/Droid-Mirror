package app.droidmirror.bluetooth.bridge

import android.content.BroadcastReceiver
import android.content.IntentFilter
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.content.Context
import android.content.Intent
import android.content.pm.ResolveInfo
import android.graphics.Bitmap
import android.graphics.Canvas
import android.os.SystemClock
import android.util.Base64
import org.json.JSONArray
import org.json.JSONObject
import java.io.ByteArrayOutputStream
import java.security.MessageDigest
import java.util.concurrent.Executors

/** Pull-only library: metadata first, one bounded icon chunk at a time. No unsolicited bulk stream. */
class PhoneAppLibrary(private val context: Context, private val ready: () -> Boolean, private val opener: (String) -> Boolean) {
    private val worker = Executors.newSingleThreadExecutor { task ->
        Thread(task, "phone-app-library").apply { priority = Thread.MIN_PRIORITY }
    }
    private val launchWorker = Executors.newSingleThreadExecutor { task -> Thread(task, "phone-app-launch") }
    private data class App(val info: ResolveInfo, val component: String, val label: String, val version: String)
    private var apps = listOf<App>()
    private var snapshot = ""
    private var scannedAt = -60000L
    private var iconKey = ""
    private var iconBytes = ByteArray(0)
    @Volatile private var closed = false
    @Volatile private var lane: PhoneLibraryLane? = null
    private var catalogAuthorized: (() -> Boolean)? = null
    private var catalogReply: ((JSONObject) -> Unit)? = null
    private val main = Handler(Looper.getMainLooper())
    private val catalogChanged = Runnable {
        if (!closed) worker.execute {
            if (closed) return@execute
            scannedAt = -60000L
            val valid = catalogAuthorized
            val reply = catalogReply
            if (valid?.invoke() == true && reply != null) {
                val before = snapshot
                runCatching { scan() }.onSuccess {
                    if (snapshot != before && !closed && valid()) reply(JSONObject().put("success", true).put("snapshot", snapshot))
                }
            }
        }
    }
    private val packagesChanged = object : BroadcastReceiver() {
        override fun onReceive(context: Context, intent: Intent) {
            main.removeCallbacks(catalogChanged); main.postDelayed(catalogChanged, 300)
        }
    }
    init {
        val packages = IntentFilter().apply {
            addAction(Intent.ACTION_PACKAGE_ADDED); addAction(Intent.ACTION_PACKAGE_REMOVED)
            addAction(Intent.ACTION_PACKAGE_CHANGED); addAction(Intent.ACTION_PACKAGE_REPLACED)
            addDataScheme("package")
        }
        val configuration = IntentFilter().apply {
            addAction(Intent.ACTION_LOCALE_CHANGED); addAction(Intent.ACTION_CONFIGURATION_CHANGED)
            addAction(Intent.ACTION_EXTERNAL_APPLICATIONS_AVAILABLE); addAction(Intent.ACTION_EXTERNAL_APPLICATIONS_UNAVAILABLE)
        }
        if (Build.VERSION.SDK_INT >= 33) {
            context.registerReceiver(packagesChanged, packages, Context.RECEIVER_NOT_EXPORTED)
            context.registerReceiver(packagesChanged, configuration, Context.RECEIVER_NOT_EXPORTED)
        } else {
            context.registerReceiver(packagesChanged, packages)
            context.registerReceiver(packagesChanged, configuration)
        }
    }
    private val launchGeneration = java.util.concurrent.atomic.AtomicLong()

    private fun scan() {
        if (SystemClock.elapsedRealtime() - scannedAt < 15000) return
        val pm = context.packageManager
        val intent = Intent(Intent.ACTION_MAIN).addCategory(Intent.CATEGORY_LAUNCHER)
        val next = pm.queryIntentActivities(intent, 0).filter { it.activityInfo.enabled && it.activityInfo.exported }
            .mapNotNull { info -> runCatching {
                val pkg = pm.getPackageInfo(info.activityInfo.packageName, 0)
                val component = android.content.ComponentName(info.activityInfo.packageName, info.activityInfo.name).flattenToString()
                require(component.length <= 512)
                App(info, component, info.loadLabel(pm).toString().take(160), "${pkg.longVersionCode}:${pkg.lastUpdateTime}")
            }.getOrNull() }.distinctBy { it.component }.sortedBy { it.component }.take(4096)
        apps = next
        snapshot = MessageDigest.getInstance("SHA-256").digest(next.joinToString("\n") {
            "${it.component}:${it.label}:${it.version}"
        }.toByteArray()).joinToString("") { "%02x".format(it) }
        scannedAt = SystemClock.elapsedRealtime()
    }
    fun receive(command: JSONObject, authorized: () -> Boolean, reply: (JSONObject) -> Unit, bulk: Boolean = false) {
        if (closed) return
        val queuedAt = SystemClock.elapsedRealtime()
        val launch = if (command.optString("type") == "appLaunch") launchGeneration.incrementAndGet() else launchGeneration.get()
        val executor = if (command.optString("type") == "appLaunch") launchWorker else worker
        executor.execute {
            if (closed || !authorized()) return@execute
            val result = runCatching {
                when (command.optString("type")) {
                    "appCatalogSubscribe" -> {
                        catalogAuthorized = authorized; catalogReply = reply
                        scannedAt = -60000L; scan()
                        JSONObject().put("success", true).put("snapshot", snapshot)
                    }
                    "appLibraryOffer" -> {
                        val token = command.getString("token")
                        require(token.matches(Regex("[a-fA-F0-9]{64}")))
                        lane?.close(); lane = null
                        val key = requireNotNull(BleTrust.key(context)).copyOf()
                        val fresh = PhoneLibraryLane(context, key, token, authorized) { request, done ->
                            receive(request, authorized, done, bulk = true)
                        }
                        lane = fresh
                        var addresses = fresh.addresses(context)
                        for (attempt in 0 until 15) {
                            if (addresses.length() > 0 || !authorized()) break
                            Thread.sleep(100); addresses = fresh.addresses(context)
                        }
                        JSONObject().put("success", addresses.length() > 0 && authorized()).put("addresses", addresses)
                    }
                    "appCatalogRequest" -> {
                        val offset = command.optInt("offset", -1)
                        require(offset in 0..4096)
                        if (offset == 0) scan()
                        require(offset == 0 || command.optString("snapshot") == snapshot)
                        require(offset <= apps.size)
                        if (offset == 0 && command.optString("snapshot") == snapshot)
                            return@runCatching JSONObject().put("success", true).put("unchanged", true).put("snapshot", snapshot)
                        val page = JSONArray()
                        // Small pages make every app searchable before any artwork is requested.
                        for (app in apps.drop(offset).take(8)) {
                            val entry = JSONObject().put("component", app.component).put("label", app.label).put("version", app.version)
                            // Bound UTF-8 bytes too: non-Latin labels can be several bytes per character.
                            if (page.toString().toByteArray(Charsets.UTF_8).size + entry.toString().toByteArray(Charsets.UTF_8).size > 4500) break
                            page.put(entry)
                        }
                        JSONObject().put("success", true).put("snapshot", snapshot).put("offset", offset)
                            .put("total", apps.size).put("apps", page)
                    }
                    "appIconRequest" -> {
                        val component = command.getString("component")
                        val app = apps.first { it.component == component && it.version == command.getString("version") }
                        val size = command.optInt("size")
                        require(size == 48 || size == 256)
                        val key = "$component:${app.version}:$size"
                        if (key != iconKey) {
                            val drawable = app.info.loadIcon(context.packageManager)
                            val bitmap = Bitmap.createBitmap(size, size, Bitmap.Config.ARGB_8888)
                            val out = ByteArrayOutputStream()
                            try {
                                drawable.setBounds(0, 0, size, size); drawable.draw(Canvas(bitmap))
                                bitmap.compress(Bitmap.CompressFormat.PNG, 100, out)
                            } finally { bitmap.recycle() }
                            val bytes = out.toByteArray()
                            require(bytes.size in 1..262144)
                            iconKey = key; iconBytes = bytes
                        }
                        val offset = command.optInt("offset", -1)
                        val chunkSize = if (bulk) 32768 else 768
                        require(offset >= 0 && offset < iconBytes.size && offset % chunkSize == 0)
                        val bytes = iconBytes.copyOfRange(offset, minOf(offset + chunkSize, iconBytes.size))
                        JSONObject().put("success", true).put("component", component).put("version", app.version)
                            .put("size", size).put("offset", offset).put("total", iconBytes.size)
                            .put("hash", MessageDigest.getInstance("SHA-256").digest(iconBytes).joinToString("") { "%02x".format(it) })
                            .put("data", Base64.encodeToString(bytes, Base64.NO_WRAP))
                    }
                    "appLaunch" -> {
                        android.util.Log.i("DroidMirrorApps", "Launch worker queue wait: ${SystemClock.elapsedRealtime() - queuedAt}ms")
                        val component = requireNotNull(android.content.ComponentName.unflattenFromString(command.getString("component")))
                        val intent = Intent(Intent.ACTION_MAIN).addCategory(Intent.CATEGORY_LAUNCHER).setComponent(component)
                        require(context.packageManager.queryIntentActivities(intent, 0).any {
                            it.activityInfo.enabled && it.activityInfo.exported
                        })
                        // Resolve only the requested component; never rescan the whole library on a click.
                        // Explicit click may wait briefly for the mirror's unlock flow. No replay on reconnect.
                        val deadline = SystemClock.elapsedRealtime() + 25000
                        val keyguard = context.getSystemService(android.app.KeyguardManager::class.java)
                        while ((keyguard.isKeyguardLocked || !ready()) && launchGeneration.get() == launch && !closed && authorized() && SystemClock.elapsedRealtime() < deadline)
                            Thread.sleep(250)
                        android.util.Log.i("DroidMirrorApps", "Launch ready at ${SystemClock.elapsedRealtime() - queuedAt}ms; locked=${keyguard.isKeyguardLocked} ready=${ready()}")
                        val success = !closed && launchGeneration.get() == launch && authorized() && ready() && !keyguard.isKeyguardLocked && opener(component.flattenToString())
                        android.util.Log.i("DroidMirrorApps", "Launch complete at ${SystemClock.elapsedRealtime() - queuedAt}ms; success=$success")
                        JSONObject().put("success", success).put("displayedAtUs", if (success) System.nanoTime() / 1000 else 0)
                    }
                    else -> error("unsupported")
                }
            }.getOrElse { JSONObject().put("success", false) }
            if (!closed && authorized()) reply(result)
        }
    }
    fun close() { closed = true; main.removeCallbacksAndMessages(null); runCatching { context.unregisterReceiver(packagesChanged) }; lane?.close(); lane = null; worker.shutdownNow(); launchWorker.shutdownNow() }
}
