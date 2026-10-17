package app.droidmirror.bluetooth;

import android.opengl.*;
import android.view.Surface;
import com.genymobile.scrcpy.Options;
import com.genymobile.scrcpy.device.Streamer;
import com.genymobile.scrcpy.model.Size;
import com.genymobile.scrcpy.video.*;
import java.io.FileOutputStream;
import java.util.concurrent.CountDownLatch;
import java.util.concurrent.TimeUnit;

/** Synthetic GPU frames only: exercises the real SurfaceEncoder and hybrid HEVC policy. */
public final class HybridHevcPhoneProbe {
    private static final class SyntheticCapture extends SurfaceCapture {
        private VideoConstraints constraints;
        private Size size;
        private volatile boolean running;
        private Thread painter;
        final java.util.concurrent.BlockingQueue<Size> started = new java.util.concurrent.LinkedBlockingQueue<>();
        volatile Throwable failure;
        @Override protected void init(VideoConstraints value) { constraints=value; }
        @Override protected boolean applyNewVideoConstraints(VideoConstraints value) { constraints=value; return true; }
        @Override public void prepare() { size=new Size(1080,2400).constrain(constraints); }
        @Override public Size getSize() { return size; }
        @Override public void release() { stop(); }
        @Override public void start(Surface target) {
            running=true;
            final Size dimensions=size;
            final int fps=dimensions.getHeight()>1200 ? 60 : 16;
            painter=new Thread(() -> paint(target,dimensions,fps),"SyntheticHevcFrames");
            painter.start();
        }
        @Override public void stop() {
            running=false;
            if (painter!=null) {
                try { painter.join(3000); } catch (InterruptedException error) { Thread.currentThread().interrupt(); }
                if (painter.isAlive()) throw new AssertionError("Synthetic renderer did not stop");
                painter=null;
            }
        }
        private void paint(Surface target, Size dimensions, int fps) {
            EGLDisplay display=EGL14.eglGetDisplay(EGL14.EGL_DEFAULT_DISPLAY);
            EGLContext context=EGL14.EGL_NO_CONTEXT;
            EGLSurface surface=EGL14.EGL_NO_SURFACE;
            try {
                int[] version=new int[2];
                if (!EGL14.eglInitialize(display,version,0,version,1)) throw new AssertionError("EGL initialize");
                int[] attributes={EGL14.EGL_RED_SIZE,8,EGL14.EGL_GREEN_SIZE,8,EGL14.EGL_BLUE_SIZE,8,
                    EGL14.EGL_RENDERABLE_TYPE,EGL14.EGL_OPENGL_ES2_BIT,0x3142,1,EGL14.EGL_NONE};
                EGLConfig[] configs=new EGLConfig[1]; int[] count=new int[1];
                if (!EGL14.eglChooseConfig(display,attributes,0,configs,0,1,count,0) || count[0]==0) throw new AssertionError("EGL config");
                context=EGL14.eglCreateContext(display,configs[0],EGL14.EGL_NO_CONTEXT,
                    new int[]{EGL14.EGL_CONTEXT_CLIENT_VERSION,2,EGL14.EGL_NONE},0);
                surface=EGL14.eglCreateWindowSurface(display,configs[0],target,new int[]{EGL14.EGL_NONE},0);
                if (!EGL14.eglMakeCurrent(display,surface,surface,context)) throw new AssertionError("EGL current");
                started.offer(dimensions);
                int frame=0;
                while (running) {
                    GLES20.glDisable(GLES20.GL_SCISSOR_TEST);
                    GLES20.glClearColor(0.08f,0.08f,0.08f,1); GLES20.glClear(GLES20.GL_COLOR_BUFFER_BIT);
                    GLES20.glEnable(GLES20.GL_SCISSOR_TEST);
                    for (int row=0;row<12;row++) {
                        GLES20.glScissor(30,40+row*dimensions.getHeight()/14,
                            dimensions.getWidth()-60-(frame%4)*8,Math.max(4,dimensions.getHeight()/150));
                        GLES20.glClearColor(0.95f,0.95f,0.95f,1); GLES20.glClear(GLES20.GL_COLOR_BUFFER_BIT);
                    }
                    EGLExt.eglPresentationTimeANDROID(display,surface,System.nanoTime());
                    if (!EGL14.eglSwapBuffers(display,surface)) {
                        if (running) throw new AssertionError("EGL swap");
                        break;
                    }
                    frame++; Thread.sleep(1000/fps);
                }
            } catch (Throwable error) { failure=error; }
            finally {
                EGL14.eglMakeCurrent(display,EGL14.EGL_NO_SURFACE,EGL14.EGL_NO_SURFACE,EGL14.EGL_NO_CONTEXT);
                if (surface!=EGL14.EGL_NO_SURFACE) EGL14.eglDestroySurface(display,surface);
                if (context!=EGL14.EGL_NO_CONTEXT) EGL14.eglDestroyContext(display,context);
                EGL14.eglTerminate(display);
            }
        }
    }
    public static void main(String[] args) throws Exception {
        HevcCaptureCodec codec=HevcCaptureCodec.select();
        System.out.println("Synthetic HEVC encoder="+codec.name+" options="+codec.bluetoothOptions());
        SyntheticCapture capture=new SyntheticCapture();
        CountDownLatch first=new CountDownLatch(1), ended=new CountDownLatch(1);
        try (FileOutputStream output=new FileOutputStream(args[0])) {
            Options initial=Options.parse("5.0","video_codec="+HevcCapturePolicy.CODEC,"video_encoder="+codec.name,
                "video_bit_rate=256000","max_fps=16","max_size=1040","downsize_on_error=false",
                "video_codec_options="+codec.bluetoothOptions());
            Streamer streamer=new Streamer(output.getFD(),initial.getVideoCodec(),true,true);
            SurfaceEncoder encoder=new SurfaceEncoder(capture,streamer,initial);
            encoder.setMaxFrameAgeUs(2000000); encoder.setFirstFrameListener(first::countDown);
            encoder.start(fatal -> ended.countDown());
            try {
                if (!first.await(8,TimeUnit.SECONDS)) throw new AssertionError("No Bluetooth-profile HEVC frame");
                Thread.sleep(400);
                if (capture.started.poll(8,TimeUnit.SECONDS)==null) throw new AssertionError("No initial capture surface");
                for (int limit : new int[]{1920,-1,1920,1280,0,-1}) {
                    if (limit==-1) encoder.requestVideoProfile(initial,2000000);
                    else encoder.requestVideoProfile(Options.parse("5.0","video_codec="+HevcCapturePolicy.CODEC,"max_size="+limit,
                        "max_fps=60","video_bit_rate=12000000","video_codec_options="+HevcCapturePolicy.WIFI_OPTIONS));
                    if (capture.started.poll(8,TimeUnit.SECONDS)==null) throw new AssertionError("No profile reconfiguration for limit="+limit);
                    Thread.sleep(450);
                }
            } finally {
                encoder.stop();
                if (!ended.await(8,TimeUnit.SECONDS)) throw new AssertionError("Encoder did not stop");
                encoder.join();
            }
        }
        if (capture.failure!=null) throw new AssertionError("Synthetic GPU renderer failed",capture.failure);
        System.out.println("Synthetic Bluetooth/Wi-Fi HEVC upgrade, fallback and repeated upgrade finished");
    }
}
