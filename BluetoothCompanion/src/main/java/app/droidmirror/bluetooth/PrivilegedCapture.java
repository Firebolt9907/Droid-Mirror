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
        Options options = Options.parse("5.0", "audio=false", "control=true", "clipboard_autosync=false", "power_on=false", "cleanup=false", "video_codec=h264",
            "video_bit_rate=64000", "max_fps=8", "max_size=" + longest, "min_size_alignment=16",
            // Hard QP limits force oversized frames even after bitrate reductions.
            // Refresh image detail gradually, including after motion has stopped.
            "video_codec_options=bitrate-mode:int=2,frame-rate:int=8,max-bframes:int=0,intra-refresh-period:int=8,i-frame-interval=60,repeat-previous-frame-after:long=125000");
        Streamer streamer = new Streamer(output.getFileDescriptor(), options.getVideoCodec(), true, true);
        com.genymobile.scrcpy.control.ControlChannel channel = new com.genymobile.scrcpy.control.ControlChannel(
            new java.io.FileInputStream(controls.getFileDescriptor()), new java.io.FileOutputStream(controls.getFileDescriptor()));
        controller = new com.genymobile.scrcpy.control.Controller(channel, null, options);
        ScreenCapture screen = new ScreenCapture(controller, options);
        controller.setSurfaceCapture(screen);
        encoder = new SurfaceEncoder(screen, streamer, options);
        encoder.setMaxFrameAgeUs(2000000);
        controller.start(fatal -> ended.run());
        encoder.start(fatal -> ended.run());
    }
    @Override public synchronized void close() {
        if (closed) return;
        closed = true; controller.stop(); encoder.stop();
        try { controls.close(); } catch (java.io.IOException ignored) {}
        try { output.close(); } catch (java.io.IOException ignored) {}
        // Do not block the recovery watchdog joining a stuck codec/driver thread.
    }
}
