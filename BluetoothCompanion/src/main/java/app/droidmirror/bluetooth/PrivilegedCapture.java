package app.droidmirror.bluetooth;

import android.os.ParcelFileDescriptor;
import com.genymobile.scrcpy.Options;
import com.genymobile.scrcpy.Workarounds;
import com.genymobile.scrcpy.device.Streamer;
import com.genymobile.scrcpy.model.Size;
import com.genymobile.scrcpy.video.ScreenCapture;
import com.genymobile.scrcpy.video.SurfaceEncoder;
import com.genymobile.scrcpy.wrappers.ServiceManager;

/** Embeds scrcpy's shell capture path. No MediaProjection token or per-session consent UI. */
final class PrivilegedCapture implements AutoCloseable {
    private final ParcelFileDescriptor output;
    private final SurfaceEncoder encoder;
    private final com.genymobile.scrcpy.control.Controller controller;
    private final ParcelFileDescriptor controls;
    private final Options bluetoothProfile;
    private boolean closed;
    private static boolean initialized;
    static synchronized void initialize() throws Exception {
        if (!initialized) {
            // scrcpy constructs ActivityThread, whose Handler needs a prepared Looper.
            // Capture requests arrive on Shizuku Binder threads without one.
            java.util.concurrent.FutureTask<Void> setup = new java.util.concurrent.FutureTask<>(() -> {
                Workarounds.apply(); return null;
            });
            android.os.Looper main = android.os.Looper.getMainLooper();
            if (android.os.Looper.myLooper() == main) setup.run();
            else if (!new android.os.Handler(main).post(setup)) throw new IllegalStateException("Capture initialization unavailable");
            setup.get(5, java.util.concurrent.TimeUnit.SECONDS);
            initialized = true;
        }
    }
    PrivilegedCapture(ParcelFileDescriptor output, ParcelFileDescriptor controls, Runnable ended) throws Exception {
        initialize();
        this.output = output; this.controls = controls;
        // Linux F_SETPIPE_SZ: keep the encoder from queuing seconds of old frames
        // between Shizuku and the app. Android does not expose this constant.
        if (android.os.Build.VERSION.SDK_INT >= 30) {
            android.system.Os.fcntlInt(output.getFileDescriptor(), 1031, 4096);
        }
        Size source = ServiceManager.getDisplayManager().getDisplayInfo(0).getSize();
        int[] target = VideoWire.dimensions(source.getWidth(), source.getHeight());
        int longest = Math.max(target[0], target[1]);
        HevcCaptureCodec codec = HevcCaptureCodec.select();
        android.util.Log.i("DroidMirrorCapture", "Hybrid HEVC encoder: " + codec.name);
        Options options = Options.parse("5.0", "audio=false", "control=true", "clipboard_autosync=false", "power_on=false", "cleanup=false",
            "video_codec=" + HevcCapturePolicy.CODEC, "video_encoder=" + codec.name,
            "video_bit_rate=" + HevcCapturePolicy.BLUETOOTH_BIT_RATE, "max_fps=" + HevcCapturePolicy.BLUETOOTH_FPS, "max_size=" + longest, "downsize_on_error=false",
            // Hard QP limits force oversized frames even after bitrate reductions.
            // Refresh image detail gradually, including after motion has stopped.
            "video_codec_options=" + codec.bluetoothOptions());
        bluetoothProfile=options;
        Streamer streamer = new Streamer(output.getFileDescriptor(), options.getVideoCodec(), true, true);
        com.genymobile.scrcpy.control.ControlChannel channel = new com.genymobile.scrcpy.control.ControlChannel(
            new java.io.FileInputStream(controls.getFileDescriptor()), new java.io.FileOutputStream(controls.getFileDescriptor()));
        controller = new com.genymobile.scrcpy.control.Controller(channel, null, options);
        ScreenCapture screen = new ScreenCapture(controller, options);
        controller.setSurfaceCapture(screen);
        encoder = new SurfaceEncoder(screen, streamer, options);
        // Bound codec backlog before it becomes seconds of delayed interaction.
        encoder.setMaxFrameAgeUs(HevcCapturePolicy.BLUETOOTH_MAX_FRAME_AGE_US);
        // Keep recovery within the Classic budget. Wi-Fi uses its explicit profile.
        encoder.setMaxAdaptiveBitRate(HevcCapturePolicy.BLUETOOTH_MAX_BIT_RATE);
        controller.start(fatal -> ended.run());
        encoder.start(fatal -> ended.run());
    }
    synchronized void upgradeVideo(WirelessVideoProfile profile) {
        if (closed) throw new IllegalStateException("Capture ended");
        Options options = Options.parse("5.0", "video_codec=" + HevcCapturePolicy.CODEC, "max_size=" + profile.maxSize,
            "max_fps=" + profile.fps, "video_bit_rate=" + profile.bitRate,
            "video_codec_options=" + HevcCapturePolicy.WIFI_OPTIONS);
        // Reuse scrcpy's EOS/reset path. It emits new session metadata and codec
        // configuration on the existing stream without another device header.
        encoder.requestVideoProfile(options);

    }
    synchronized void restoreBluetoothVideo() {
        if (closed) throw new IllegalStateException("Capture ended");
        encoder.requestVideoProfile(bluetoothProfile,HevcCapturePolicy.BLUETOOTH_MAX_FRAME_AGE_US);
    }
    @Override public synchronized void close() {
        if (closed) return;
        closed = true; controller.stop(); encoder.stop();
        try { controls.close(); } catch (java.io.IOException ignored) {}
        try { output.close(); } catch (java.io.IOException ignored) {}
        // Do not block the recovery watchdog joining a stuck codec/driver thread.
    }
}
