package app.droidmirror.bluetooth;

import android.os.ParcelFileDescriptor;
import com.genymobile.scrcpy.audio.*;
import com.genymobile.scrcpy.device.Streamer;

/** Opt-in shell output capture. Never records a microphone or starts a foreground activity. */
final class PrivilegedAudioCapture implements AutoCloseable {
    private final ParcelFileDescriptor output;
    private final AudioVolumeLease volume;
    private final java.util.concurrent.atomic.AtomicBoolean released = new java.util.concurrent.atomic.AtomicBoolean();
    private final java.util.concurrent.atomic.AtomicBoolean restoring = new java.util.concurrent.atomic.AtomicBoolean();
    private static final class OutputCapture extends AudioDirectCapture {
        private boolean stopped;
        OutputCapture() { super(AudioSource.OUTPUT); }
        @Override public synchronized void start() throws AudioCaptureException {
            if (stopped) throw new AudioCaptureException();
            super.start();
        }
        @Override public synchronized void stop() {
            if (stopped) return;
            stopped = true; super.stop();
        }
    }
    private final AudioCapture capture = new OutputCapture();
    private final java.util.concurrent.atomic.AtomicBoolean closed = new java.util.concurrent.atomic.AtomicBoolean();
    private final AudioRawRecorder recorder;
    PrivilegedAudioCapture(ParcelFileDescriptor output) throws Exception {
        PrivilegedCapture.initialize();
        this.output = output;
        capture.checkCompatibility();
        volume = new AudioVolumeLease(new PhoneAudioVolume());
        recorder = new AudioRawRecorder(capture, new Streamer(output.getFileDescriptor(), AudioCodec.RAW, true, true));
        recorder.start(fatal -> {
            closed.set(true);
            try { output.close(); } catch (java.io.IOException ignored) {}
            release();
        });
    }
    boolean isReleased() { return released.get(); }
    void retryRelease() {
        if (closed.get() && !released.get()) new Thread(this::release, "WirelessAudioRecovery").start();
    }
    private void release() {
        if (released.get() || !restoring.compareAndSet(false, true)) return;
        try {
            capture.stop(); // Restore only after REMOTE_SUBMIX gives up the output.
            for (int attempt = 0; attempt < 3; attempt++) {
                try { volume.restore(); released.set(true); return; }
                catch (Exception error) {
                    android.util.Log.w("DroidMirrorAudio", "Could not restore media volume", error);
                    android.os.SystemClock.sleep(100);
                }
            }
        } finally { restoring.set(false); }
    }
    @Override public void close() {
        if (!closed.compareAndSet(false, true)) return;
        recorder.stop();
        try { output.close(); } catch (java.io.IOException ignored) {}
        // Also release a blocked AudioRecord.read, without joining a driver on
        // the display recovery watchdog or Binder thread.
        new Thread(this::release, "WirelessAudioRelease").start();
    }
}
