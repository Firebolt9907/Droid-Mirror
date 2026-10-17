package app.droidmirror.bluetooth.bridge

import android.content.Context
import android.content.pm.PackageManager
import android.net.nsd.NsdManager
import android.net.nsd.NsdServiceInfo
import android.provider.Settings
import java.io.DataInputStream
import java.net.Inet4Address
import java.net.InetSocketAddress
import java.net.NetworkInterface
import java.net.Socket
import java.nio.ByteBuffer
import java.nio.ByteOrder
import java.util.concurrent.Executors
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicInteger

data class AdbEndpoint(val port: Int, val tailscaleIp: String?)

class AdbEndpointFinder(private val context: Context) {
    @Volatile var endpoint: AdbEndpoint? = null
        private set

    fun hasSecureSettingsPermission(): Boolean =
        context.checkSelfPermission("android.permission.WRITE_SECURE_SETTINGS") ==
            PackageManager.PERMISSION_GRANTED

    fun enableAndFind(onStatus: (String) -> Unit, onDone: (Result<AdbEndpoint>) -> Unit) {
        Thread {
            try {
                val alreadyEnabled = Settings.Global.getInt(
                    context.contentResolver,
                    "adb_wifi_enabled",
                    0
                ) == 1
                if (!alreadyEnabled) {
                    if (!hasSecureSettingsPermission()) {
                        error("Wireless debugging is off. Authorize Shizuku in DroidMirror to grant secure settings, or enable Wireless debugging manually.")
                    }
                    onStatus("Requesting Wireless Debugging…")
                    check(Settings.Global.putInt(context.contentResolver, "adb_wifi_enabled", 1)) {
                        "Android rejected adb_wifi_enabled"
                    }
                } else {
                    onStatus("Wireless Debugging is already on; finding port…")
                }

                var port: Int? = null
                for (attempt in 0 until 20) {
                    Thread.sleep(250)
                    if (Settings.Global.getInt(
                            context.contentResolver,
                            "adb_wifi_enabled",
                            0
                        ) == 0
                    ) {
                        error("Android turned Wireless Debugging off. Connect to a trusted Wi-Fi network.")
                    }
                    port = readPortProperty()
                    if (port != null) break
                }

                if (port == null) {
                    onStatus("Discovering Android's ADB service…")
                    port = findPortWithNsd()
                }
                if (port == null) {
                    onStatus("Port property is protected; probing localhost…")
                    port = findAdbListener()
                }
                val foundPort = port ?: error("ADB TLS listener was not found")
                val result = AdbEndpoint(foundPort, findTailscaleIpv4())
                endpoint = result
                onDone(Result.success(result))
            } catch (t: Throwable) {
                endpoint = null
                onDone(Result.failure(t))
            }
        }.start()
    }

    /**
     * Cheap background refresh: verify the known listener first, then use the
     * property/mDNS paths. It deliberately avoids the full 35k-port fallback scan.
     */
    fun refreshExisting(onDone: (Result<AdbEndpoint?>) -> Unit) {
        Thread {
            try {
                val current = endpoint
                // Always prefer the currently advertised port. Android can bring
                // up a replacement before the previous listener fully disappears.
                val advertisedPort = readPortProperty() ?: findPortWithNsd()
                endpoint = when {
                    advertisedPort != null -> AdbEndpoint(advertisedPort, findTailscaleIpv4())
                    current != null && isAdbTlsPort(current.port) -> current
                    else -> null
                }
                onDone(Result.success(endpoint))
            } catch (t: Throwable) {
                onDone(Result.failure(t))
            }
        }.start()
    }

    private fun readPortProperty(): Int? = runCatching {
        ProcessBuilder("/system/bin/getprop", "service.adb.tls.port")
            .redirectErrorStream(true)
            .start()
            .inputStream.bufferedReader().use { it.readText().trim().toIntOrNull() }
            ?.takeIf { it in 1..65535 }
    }.getOrNull()

    private fun findPortWithNsd(): Int? {
        val nsd = context.getSystemService(NsdManager::class.java)
        val found = AtomicInteger(-1)
        val resolving = AtomicBoolean(false)
        val done = CountDownLatch(1)

        lateinit var listener: NsdManager.DiscoveryListener
        listener = object : NsdManager.DiscoveryListener {
            override fun onDiscoveryStarted(serviceType: String) = Unit

            override fun onServiceFound(service: NsdServiceInfo) {
                if (found.get() > 0 || !resolving.compareAndSet(false, true)) return
                @Suppress("DEPRECATION")
                nsd.resolveService(service, object : NsdManager.ResolveListener {
                    override fun onResolveFailed(serviceInfo: NsdServiceInfo, errorCode: Int) {
                        resolving.set(false)
                    }

                    override fun onServiceResolved(serviceInfo: NsdServiceInfo) {
                        // mDNS also sees other phones. Advertise only a listener
                        // verified on this phone's loopback interface.
                        if (serviceInfo.port in 1..65535 && isAdbTlsPort(serviceInfo.port)) found.set(serviceInfo.port)
                        done.countDown()
                    }
                })
            }

            override fun onServiceLost(service: NsdServiceInfo) = Unit
            override fun onDiscoveryStopped(serviceType: String) = Unit
            override fun onStartDiscoveryFailed(serviceType: String, errorCode: Int) = done.countDown()
            override fun onStopDiscoveryFailed(serviceType: String, errorCode: Int) = Unit
        }

        return try {
            nsd.discoverServices("_adb-tls-connect._tcp.", NsdManager.PROTOCOL_DNS_SD, listener)
            done.await(4, TimeUnit.SECONDS)
            found.get().takeIf { it > 0 }
        } catch (_: Throwable) {
            null
        } finally {
            runCatching { nsd.stopServiceDiscovery(listener) }
        }
    }

    private fun findTailscaleIpv4(): String? = runCatching {
        NetworkInterface.getNetworkInterfaces().toList()
            .flatMap { it.inetAddresses.toList() }
            .filterIsInstance<Inet4Address>()
            .firstOrNull { address ->
                val b = address.address
                (b[0].toInt() and 0xff) == 100 && (b[1].toInt() and 0xc0) == 64
            }?.hostAddress
    }.getOrNull()

    private fun findAdbListener(): Int? {
        val next = AtomicInteger(30_000)
        val found = AtomicInteger(-1)
        val workers = Executors.newFixedThreadPool(64)
        repeat(64) {
            workers.execute {
                while (found.get() < 0) {
                    val port = next.getAndIncrement()
                    if (port > 65_535) break
                    if (isAdbTlsPort(port)) found.compareAndSet(-1, port)
                }
            }
        }
        workers.shutdown()
        workers.awaitTermination(8, TimeUnit.SECONDS)
        workers.shutdownNow()
        return found.get().takeIf { it > 0 }
    }

    private fun isAdbTlsPort(port: Int): Boolean = runCatching {
        Socket().use { socket ->
            socket.connect(InetSocketAddress("127.0.0.1", port), 35)
            socket.soTimeout = 180
            val payload = "host::\u0000".toByteArray(Charsets.UTF_8)
            val command = 0x4e584e43 // CNXN, little-endian on the wire
            val packet = ByteBuffer.allocate(24 + payload.size).order(ByteOrder.LITTLE_ENDIAN)
                .putInt(command)
                .putInt(0x01000001)
                .putInt(1024 * 1024)
                .putInt(payload.size)
                .putInt(payload.sumOf { it.toInt() and 0xff })
                .putInt(command xor -1)
                .put(payload)
                .array()
            socket.getOutputStream().write(packet)
            socket.getOutputStream().flush()
            val reply = ByteArray(24)
            DataInputStream(socket.getInputStream()).readFully(reply)
            val replyCommand = ByteBuffer.wrap(reply).order(ByteOrder.LITTLE_ENDIAN).int
            replyCommand == 0x534c5453 || // STLS
                replyCommand == 0x48545541 || // AUTH
                replyCommand == 0x4e584e43 // CNXN
        }
    }.getOrDefault(false)
}
