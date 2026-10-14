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
    private boolean closed;
    private static boolean initialized;
    private static synchronized void initialize() {
        if (!initialized) { Workarounds.apply(); initialized = true; }
    }
    PrivilegedCapture(ParcelFileDescriptor output, Runnable ended) {
        initialize();
        this.output = output;
        Size source = ServiceManager.getDisplayManager().getDisplayInfo(0).getSize();
        int[] target = VideoWire.dimensions(source.getWidth(), source.getHeight());
        int longest = Math.max(target[0], target[1]);
        Options options = Options.parse("5.0", "audio=false", "control=false", "cleanup=false", "video_codec=h264",
            "video_bit_rate=1000000", "max_fps=30", "max_size=" + longest, "min_size_alignment=16",
            "video_codec_options=i-frame-interval=2,repeat-previous-frame-after:long=1000000");
        Streamer streamer = new Streamer(output.getFileDescriptor(), options.getVideoCodec(), true, true);
        encoder = new SurfaceEncoder(new ScreenCapture(null, options), streamer, options);
        encoder.start(fatal -> ended.run());
    }
    @Override public synchronized void close() {
        if (closed) return;
        closed = true; encoder.stop();
        try { output.close(); } catch (java.io.IOException ignored) {}
        // Do not block the recovery watchdog joining a stuck codec/driver thread.
    }
}
