package app.droidmirror.bluetooth.bridge

import app.droidmirror.bluetooth.CameraVideoProfile
import app.droidmirror.bluetooth.CameraFrameWindow
import android.Manifest
import android.app.*
import android.content.*
import android.content.pm.PackageManager
import android.hardware.camera2.*
import android.media.*
import android.os.*
import android.util.Base64
import android.view.Surface
import org.json.JSONObject

/** Camera2/AVC capture is unprivileged: no surviving Shizuku process owns the camera. */
class ContinuityCameraService : Service() {
    companion object {
        private val main = Handler(Looper.getMainLooper())
        private var instance: ContinuityCameraService? = null
        fun command(context: Context, event: JSONObject, valid: () -> Boolean, send: (JSONObject) -> Boolean) {
            main.post {
                if (!valid()) return@post
                val service = instance
                when (event.optString("type")) {
                    "cameraStart" -> {
                        if (service == null) {
                            send(JSONObject().put("type", "cameraState").put("session", event.optString("session"))
                                .put("error", "Open DroidMirror phone settings and arm Phone Camera first"))
                        } else service.startCapture(event, valid, send)
                    }
                    "cameraLease" -> {
                        if (service != null && service.session == event.optString("session")) service.lease = SystemClock.elapsedRealtime()
                        else send(JSONObject().put("type", "cameraState").put("session", event.optString("session")).put("error", "Camera is idle or disarmed; renew capture"))
                    }
                    "cameraFrameAck" -> if (service?.session == event.optString("session")) service.frames.acknowledge(event.optInt("frame"))
                    "cameraKeyframe" -> if (service?.session == event.optString("session") && service.captureEpoch == event.optInt("epoch")) service.requestKeyframe()
                    "cameraStop" -> if (service?.session == event.optString("session")) service.stopCapture()
                }
            }
        }
        fun disconnected() { main.post { instance?.stopCapture() } }
    }
    private val worker = HandlerThread("DroidMirrorCamera").apply { start() }
    private val cameraHandler = Handler(worker.looper)
    private var lane: CameraIrohChannel? = null
    private var camera: CameraDevice? = null
    private var openingCamera = false
    private var onCameraReady: ((CameraDevice) -> Unit)? = null
    private var capture: CameraCaptureSession? = null
    private var encoder: MediaCodec? = null
    private var surface: Surface? = null
    private var wakeLock: PowerManager.WakeLock? = null
    @Volatile private var session: String? = null
    @Volatile private var epoch = 0
    private var lease = 0L
    private var captureEpoch = 0
    private var activeWifi = false
    private var facingBack = false
    private var nextLaneAttempt = 0L
    private val frames = CameraFrameWindow()
    private var frame = 0
    private var lastFrame = 0L
    private var config = ByteArray(0)
    private var valid: () -> Boolean = { false }
    private var send: (JSONObject) -> Boolean = { false }
    private val watchdog = object : Runnable {
        override fun run() {
            if (session != null && (!valid() || SystemClock.elapsedRealtime() - lease > 4000)) stopCapture()
            if (session != null && valid()) {
                ensureLane(SystemClock.elapsedRealtime())
                val wifi = lane?.ready == true
                if (wifi != activeWifi) configureCapture(wifi)
            }
            main.postDelayed(this, 200)
        }
    }
    override fun onCreate() {
        super.onCreate(); instance = this
        val notifications = getSystemService(NotificationManager::class.java)
        notifications.createNotificationChannel(NotificationChannel("phone-camera", "Phone Camera", NotificationManager.IMPORTANCE_LOW))
        if (Build.VERSION.SDK_INT >= 29)
            startForeground(9461, notification(false), android.content.pm.ServiceInfo.FOREGROUND_SERVICE_TYPE_CAMERA)
        else startForeground(9461, notification(false))
        main.post(watchdog)
    }
    private fun notification(live: Boolean): Notification {
        val stop = PendingIntent.getService(this, 0, Intent(this, javaClass).setAction("disarm"), PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT)
        return Notification.Builder(this, "phone-camera").setSmallIcon(android.R.drawable.ic_menu_camera)
            .setContentTitle(if (live) "Phone camera live on Mac" else "Phone camera ready for Mac")
            .setContentText(if (live) "Stop sharing to release the camera" else "Camera stays off until a Mac app uses it")
            .setOngoing(true).addAction(Notification.Action.Builder(null, "Stop sharing", stop).build()).build()
    }
    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        if (intent?.action == "disarm") { stopCapture(); stopSelf() }
        return START_NOT_STICKY
    }
    override fun onBind(intent: Intent?) = null
    private fun startCapture(event: JSONObject, isValid: () -> Boolean, reply: (JSONObject) -> Boolean) {
        val id = event.optString("session")
        if (id.length !in 1..64) return
        if (session == id) { lease = SystemClock.elapsedRealtime(); return }
        stopCapture()
        session = id; valid = isValid; send = reply; lease = SystemClock.elapsedRealtime()
        facingBack = event.optString("facing") == "back"
        frame = 0; nextLaneAttempt = 0
        wakeLock = getSystemService(PowerManager::class.java).newWakeLock(PowerManager.PARTIAL_WAKE_LOCK, "DroidMirror:PhoneCamera").apply { acquire() }
        configureCapture(false)
        ensureLane(SystemClock.elapsedRealtime())
    }
    private fun ensureLane(now: Long) {
        val id = session ?: return
        if (!valid()) return
        lane?.let { if (it.closed || it.stalled(now)) { it.close(); lane = null; nextLaneAttempt = now + 5000 } }
        if (lane != null || now < nextLaneAttempt) return
        nextLaneAttempt = now + 10000
        val owner = epoch
        runCatching {
            val channel = CameraIrohChannel(this, requireNotNull(BleTrust.key(this)), id) {
                epoch == owner && session == id && valid()
            }
            lane = channel
            if (!send(channel.offer)) { channel.close(); lane = null }
        }
    }
    private fun requestKeyframe() {
        runCatching { encoder?.setParameters(Bundle().apply { putInt(MediaCodec.PARAMETER_KEY_REQUEST_SYNC_FRAME, 0) }) }
    }
    private fun configureCapture(wifi: Boolean) {
        if (session == null || !valid()) return
        val generation = ++captureEpoch
        closeVideo(keepCamera = true)
        activeWifi = wifi; frames.clear(); lastFrame = 0
        val profile = CameraVideoProfile.forTransport(wifi)
        var waitingForKeyframe = true
        try {
            check(checkSelfPermission(Manifest.permission.CAMERA) == PackageManager.PERMISSION_GRANTED) { "Camera permission required" }
            val manager = getSystemService(CameraManager::class.java)
            val facing = if (facingBack) CameraCharacteristics.LENS_FACING_BACK else CameraCharacteristics.LENS_FACING_FRONT
            val cameraID = manager.cameraIdList.firstOrNull { manager.getCameraCharacteristics(it).get(CameraCharacteristics.LENS_FACING) == facing }
                ?: error("Requested camera unavailable")
            val codec = MediaCodec.createEncoderByType("video/avc")
            encoder = codec
            val format = MediaFormat.createVideoFormat("video/avc", profile.width, profile.height).apply {
                setInteger(MediaFormat.KEY_COLOR_FORMAT, MediaCodecInfo.CodecCapabilities.COLOR_FormatSurface)
                setInteger(MediaFormat.KEY_BIT_RATE, profile.bitRate)
                setInteger(MediaFormat.KEY_FRAME_RATE, profile.fps)
                setFloat(MediaFormat.KEY_MAX_FPS_TO_ENCODER, profile.fps.toFloat())
                setInteger(MediaFormat.KEY_I_FRAME_INTERVAL, profile.keyframeSeconds)
                setInteger(MediaFormat.KEY_MAX_B_FRAMES, 0)
            }
            codec.configure(format, null, null, MediaCodec.CONFIGURE_FLAG_ENCODE)
            surface = codec.createInputSurface(); codec.start()
            onCameraReady = { device ->
                if (captureEpoch == generation && session != null && valid()) {
                    try {
                        device.createCaptureSession(listOf(surface!!), object : CameraCaptureSession.StateCallback() {
                            override fun onConfigured(value: CameraCaptureSession) { main.post {
                                if (captureEpoch != generation || session == null || !valid()) { value.close(); return@post }
                                capture = value
                                try {
                                    val request = device.createCaptureRequest(CameraDevice.TEMPLATE_RECORD).apply {
                                        addTarget(surface!!)
                                        manager.getCameraCharacteristics(cameraID).get(CameraCharacteristics.CONTROL_AE_AVAILABLE_TARGET_FPS_RANGES)
                                            ?.filter { it.lower <= profile.fps && it.upper >= profile.fps }?.minByOrNull { it.upper - it.lower }
                                            ?.let { set(CaptureRequest.CONTROL_AE_TARGET_FPS_RANGE, it) }
                                    }.build()
                                    value.setRepeatingRequest(request, null, cameraHandler)
                                    requestKeyframe()
                                } catch (error: Exception) { captureFailed(error, generation) }
                            } }
                            override fun onConfigureFailed(value: CameraCaptureSession) { main.post {
                                value.close()
                                captureFailed(IllegalStateException("Camera configuration failed"), generation)
                            } }
                        }, cameraHandler)
                    } catch (error: Exception) { captureFailed(error, generation) }
                }
            }
            val existingCamera = camera
            if (existingCamera != null) onCameraReady?.invoke(existingCamera)
            else if (!openingCamera) {
                openingCamera = true
                val owner = epoch
                @Suppress("MissingPermission")
                try { manager.openCamera(cameraID, object : CameraDevice.StateCallback() {
                    override fun onOpened(device: CameraDevice) { main.post {
                        if (epoch != owner || session == null || !valid()) { device.close(); return@post }
                        openingCamera = false; camera = device
                        // Use the most recent profile even if the transport changed while opening.
                        onCameraReady?.invoke(device)
                    } }
                    override fun onDisconnected(device: CameraDevice) { device.close(); main.post {
                        if (epoch == owner && session != null) {
                            openingCamera = false; camera = null
                            captureFailed(IllegalStateException("Camera disconnected"), captureEpoch)
                        }
                    } }
                    override fun onError(device: CameraDevice, error: Int) { device.close(); main.post {
                        if (epoch == owner && session != null) {
                            openingCamera = false; camera = null
                            captureFailed(IllegalStateException("Camera error $error"), captureEpoch)
                        }
                    } }
                }, cameraHandler) } catch (error: Exception) { openingCamera = false; throw error }
            }
            if (captureEpoch != generation || session == null) return
            send(JSONObject().put("type", "cameraState").put("session", session).put("epoch", generation)
                .put("transport", if (wifi) "wifi" else "bluetooth").put("width", profile.width).put("height", profile.height).put("fps", profile.fps)
                .put("rotation", manager.getCameraCharacteristics(cameraID).get(CameraCharacteristics.SENSOR_ORIENTATION) ?: 0))
            getSystemService(NotificationManager::class.java).notify(9461, notification(true))
            main.post(object : Runnable {
                override fun run() {
                    if (captureEpoch != generation || session == null) return
                    try {
                        val info = MediaCodec.BufferInfo()
                        var index = codec.dequeueOutputBuffer(info, 0)
                        if (index == MediaCodec.INFO_OUTPUT_FORMAT_CHANGED) {
                            val output = codec.outputFormat
                            config = listOf("csd-0", "csd-1").mapNotNull { output.getByteBuffer(it)?.duplicate() }
                                .fold(ByteArray(0)) { bytes, buffer -> bytes + ByteArray(buffer.remaining()).also { buffer.get(it) } }
                        }
                        var drained = 0
                        while (index >= 0 && drained++ < 8) {
                            val data = ByteArray(info.size)
                            codec.getOutputBuffer(index)!!.apply { position(info.offset); limit(info.offset + info.size); get(data) }
                            codec.releaseOutputBuffer(index, false)
                            val keyframe = info.flags and MediaCodec.BUFFER_FLAG_KEY_FRAME != 0
                            if (info.flags and MediaCodec.BUFFER_FLAG_CODEC_CONFIG != 0) config = data
                            else if (data.isNotEmpty() && valid() && (!waitingForKeyframe || keyframe)) {
                                val bytes = if (keyframe) config + data else data
                                if (wifi) {
                                    if (lane?.sendFrame(generation, info.presentationTimeUs, keyframe, bytes) != true) {
                                        // Never drop dependent Wi-Fi frames into the Bluetooth encoder's stream.
                                        lane?.close(); lane = null; nextLaneAttempt = SystemClock.elapsedRealtime() + 5000
                                        configureCapture(false); return
                                    }
                                    waitingForKeyframe = false
                                } else if (keyframe && frames.available(SystemClock.elapsedRealtime()) &&
                                    SystemClock.elapsedRealtime() - lastFrame >= CameraFrameWindow.MIN_FRAME_INTERVAL_MS && bytes.size <= 131072) {
                                    frame++; lastFrame = SystemClock.elapsedRealtime(); frames.sent(frame, lastFrame)
                                    var accepted = true
                                    bytes.asList().chunked(2048).forEachIndexed { chunk, part ->
                                        if (accepted) accepted = send(JSONObject().put("type", "cameraFrame").put("session", session)
                                            .put("epoch", generation).put("frame", frame).put("chunk", chunk)
                                            .put("last", (chunk + 1) * 2048 >= bytes.size)
                                            .put("data", Base64.encodeToString(part.toByteArray(), Base64.NO_WRAP)))
                                    }
                                    if (!accepted) { fail(IllegalStateException("Camera transport backpressure")); return }
                                    waitingForKeyframe = false
                                }
                            }
                            index = codec.dequeueOutputBuffer(info, 0)
                        }
                    } catch (error: Exception) { captureFailed(error, generation); return }
                    main.postDelayed(this, 5)
                }
            })
        } catch (error: Exception) { captureFailed(error, generation) }
    }
    private fun captureFailed(error: Exception, generation: Int) {
        if (captureEpoch != generation || session == null) return
        if (activeWifi && valid()) {
            lane?.close(); lane = null; nextLaneAttempt = SystemClock.elapsedRealtime() + 30000
            configureCapture(false)
        } else fail(error)
    }
    private fun closeVideo(keepCamera: Boolean = false) {
        runCatching { capture?.stopRepeating() }; runCatching { capture?.close() }; capture = null
        if (!keepCamera) {
            runCatching { camera?.close() }; camera = null
            openingCamera = false; onCameraReady = null
        }
        runCatching { encoder?.stop() }; runCatching { encoder?.release() }; encoder = null
        surface?.release(); surface = null; config = ByteArray(0)
    }
    private fun fail(error: Exception) {
        session?.let { send(JSONObject().put("type", "cameraState").put("session", it).put("error", error.message ?: "Camera failed")) }
        stopCapture()
    }
    private fun stopCapture() {
        ++epoch; ++captureEpoch; session = null; frames.clear()
        lane?.close(); lane = null; activeWifi = false
        closeVideo()
        wakeLock?.let { if (it.isHeld) it.release() }; wakeLock = null
        getSystemService(NotificationManager::class.java).notify(9461, notification(false))
    }
    override fun onDestroy() {
        stopCapture(); instance = null; main.removeCallbacks(watchdog); worker.quitSafely(); super.onDestroy()
    }
}

/** Explicit foreground consent also satisfies Android 14 camera-FGS launch rules. */
class ContinuityCameraPermissionActivity : Activity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        if (checkSelfPermission(Manifest.permission.CAMERA) != PackageManager.PERMISSION_GRANTED)
            requestPermissions(arrayOf(Manifest.permission.CAMERA), 9461)
        else arm()
    }
    override fun onRequestPermissionsResult(requestCode: Int, permissions: Array<out String>, grantResults: IntArray) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
        if (requestCode == 9461 && grantResults.firstOrNull() == PackageManager.PERMISSION_GRANTED) arm() else finish()
    }
    private fun arm() {
        startForegroundService(Intent(this, ContinuityCameraService::class.java))
        finish()
    }
}
