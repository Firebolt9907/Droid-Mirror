package app.droidmirror.bluetooth;

import android.annotation.SuppressLint;
import android.graphics.Canvas;
import android.graphics.Bitmap;
import android.graphics.BitmapFactory;
import android.graphics.Color;
import android.graphics.PixelFormat;
import android.os.Build;
import android.os.SystemClock;
import java.util.concurrent.Executors;
import java.util.concurrent.ScheduledExecutorService;
import java.util.concurrent.TimeUnit;
import android.view.Surface;
import com.genymobile.scrcpy.display.DisplayInfo;
import com.genymobile.scrcpy.wrappers.ServiceManager;

/** Shell-owned, capture-excluded compositor layer. Never takes app/input focus. */
@SuppressLint({"PrivateApi", "BlockedPrivateApi", "SoonBlockedPrivateApi"})
final class BlackoutOverlay implements AutoCloseable {
    private final Class<?> control;
    private final Class<?> transaction;
    private Object layer;
    private Object queue;
    private Surface surface;
    private Bitmap message;
    private int width, height, stack = -1;
    private int bufferSide;
    private final ScheduledExecutorService animation = Executors.newSingleThreadScheduledExecutor(r -> {
        Thread thread = new Thread(r, "BlackoutEntrance"); thread.setDaemon(true); return thread;
    });
    private long entranceStarted;
    private float opacity, entrance;
    private Exception animationFailure;
    private boolean closing;
    static final long ENTRANCE_MS = 420, EXIT_MS = 200;

    BlackoutOverlay(byte[] messageBytes) throws Exception {
        if (Build.VERSION.SDK_INT < 31) throw new UnsupportedOperationException("Phone blackout requires Android 12 or later");
        control = Class.forName("android.view.SurfaceControl");
        transaction = Class.forName("android.view.SurfaceControl$Transaction");
        try {
            message = decode(messageBytes);
            Class<?> builderType = Class.forName("android.view.SurfaceControl$Builder");
            Object builder = builderType.getConstructor().newInstance();
            builderType.getMethod("setName", String.class).invoke(builder, "DroidMirror phone blackout");
            try {
                builderType.getMethod("setBLASTLayer").invoke(builder);
            } catch (NoSuchMethodException fallback) {
                try { builderType.getMethod("setBLAST").invoke(builder); } catch (Exception ignored) {}
            }
            builderType.getMethod("setSecure", boolean.class).invoke(builder, true);
            builderType.getMethod("setHidden", boolean.class).invoke(builder, true);
            layer = builderType.getMethod("build").invoke(builder);
            // SECURE alone substitutes black pixels in capture. SKIP_SCREENSHOT
            // omits this layer so the Mac sees the underlying app content.
            Object tx = transaction.getConstructor().newInstance();
            try {
                // Scope input trust to this shell-owned layer. A non-touchable
                // compositor surface otherwise still blocks injected touches.
                // Apply before showing it; failure must leave the layer hidden.
                transaction.getMethod("setTrustedOverlay", control, boolean.class).invoke(tx, layer, true);
                transaction.getMethod("setSkipScreenshot", control, boolean.class).invoke(tx, layer, true);
                transaction.getMethod("setLayer", control, int.class).invoke(tx, layer, Integer.MAX_VALUE);
                transaction.getMethod("apply").invoke(tx);
            } finally { ((AutoCloseable) tx).close(); }
            Class<?> blast = Class.forName("android.graphics.BLASTBufferQueue");
            DisplayInfo display = ServiceManager.getDisplayManager().getDisplayInfo(0);
            if (display == null) throw new IllegalStateException("Phone display unavailable");
            bufferSide = Math.max(display.getSize().getWidth(), display.getSize().getHeight());
            if (bufferSide <= 0) throw new IllegalStateException("Invalid phone display size");
            try {
                queue = blast.getConstructor(String.class, control, int.class, int.class, int.class)
                    .newInstance("DroidMirror phone blackout", layer, bufferSide, bufferSide, PixelFormat.RGBA_8888);
            } catch (NoSuchMethodException newer) {
                queue = blast.getConstructor(String.class, boolean.class).newInstance("DroidMirror phone blackout", true);
                blast.getMethod("update", control, int.class, int.class, int.class)
                    .invoke(queue, layer, bufferSide, bufferSide, PixelFormat.RGBA_8888);
            }
            surface = (Surface) blast.getMethod("createSurface").invoke(queue);
        } catch (Exception failure) { close(); throw failure; }
    }

    private static Bitmap decode(byte[] bytes) {
        if (bytes == null || bytes.length > 128 * 1024)
            throw new IllegalArgumentException("Phone blackout message unavailable");
        BitmapFactory.Options bounds = new BitmapFactory.Options();
        bounds.inJustDecodeBounds = true;
        BitmapFactory.decodeByteArray(bytes, 0, bytes.length, bounds);
        if (bounds.outWidth != 900 || bounds.outHeight != 800)
            throw new IllegalArgumentException("Invalid phone blackout message dimensions");
        Bitmap result = BitmapFactory.decodeByteArray(bytes, 0, bytes.length);
        if (result == null) throw new IllegalArgumentException("Invalid phone blackout message");
        return result;
    }

    synchronized void setMessage(byte[] bytes) throws Exception {
        Bitmap replacement = decode(bytes);
        Bitmap previous = message;
        message = replacement;
        width = 0; // Force the next draw even when geometry is unchanged.
        try { update(); }
        finally { previous.recycle(); }
    }

    synchronized void update() throws Exception {
        if (closing) return;
        if (animationFailure != null) throw animationFailure;
        DisplayInfo info = ServiceManager.getDisplayManager().getDisplayInfo(0);
        if (info == null) throw new IllegalStateException("Phone display unavailable");
        int w = info.getSize().getWidth(), h = info.getSize().getHeight();
        int layerStack = info.getLayerStack();
        if (width == w && height == h && stack == layerStack) return;
        // Use display pixels: Surface/BLAST can replace a layer matrix when a
        // Canvas buffer is posted, leaving a scaled 1024 buffer partially visible.
        // A full-size square covers both orientations between watchdog ticks.
        int side = Math.max(w, h);
        if (bufferSide != side) {
            queue.getClass().getMethod("update", control, int.class, int.class, int.class)
                .invoke(queue, layer, side, side, PixelFormat.RGBA_8888);
            bufferSide = side;
        }
        drawFrame(w, h);
        Object tx = transaction.getConstructor().newInstance();
        try {
            transaction.getMethod("setLayerStack", control, int.class).invoke(tx, layer, layerStack);
            transaction.getMethod("show", control).invoke(tx, layer);
            transaction.getMethod("apply").invoke(tx);
        } finally { ((AutoCloseable) tx).close(); }
        width = w;
        height = h;
        stack = layerStack;
    }

    synchronized void reveal() {
        if (!closing && entranceStarted == 0) {
            entranceStarted = SystemClock.elapsedRealtime();
            animation.scheduleWithFixedDelay(this::animateEntrance, 0, 16, TimeUnit.MILLISECONDS);
        }
    }

    private void drawFrame(int w, int h) throws Exception {
        Canvas canvas = surface.lockCanvas(null);
        try {
            // The black cover is always opaque, including both fade endpoints.
            canvas.drawColor(Color.BLACK);
            BlackoutText.draw(canvas, w, h, message, opacity, entrance);
        } finally { surface.unlockCanvasAndPost(canvas); }
    }

    private synchronized void animateEntrance() {
        if (closing || surface == null) return;
        long elapsed = SystemClock.elapsedRealtime() - entranceStarted;
        opacity = BlackoutText.ease(elapsed / 240f);
        entrance = Math.min(1, elapsed / (float) ENTRANCE_MS);
        try { drawFrame(width, height); }
        catch (Exception failure) { animationFailure = failure; animation.shutdown(); }
        if (entrance >= 1) animation.shutdown();
    }

    synchronized void fadeOut() {
        if (closing || surface == null || width <= 0) return;
        closing = true;
        animation.shutdownNow(); // No entrance frame may relight a fading overlay.
        float initialOpacity = opacity;
        long started = SystemClock.elapsedRealtime();
        try {
            while (true) {
                float progress = Math.min(1, (SystemClock.elapsedRealtime() - started) / (float) EXIT_MS);
                // Smoothstep has zero velocity at both ends.
                opacity = initialOpacity * (1 - progress * progress * (3 - 2 * progress));
                drawFrame(width, height);
                if (progress >= 1) break;
                SystemClock.sleep(16);
            }
        } catch (Exception failure) {
            android.util.Log.w("DroidMirrorBlackout", "Fade skipped during display recovery", failure);
        }
    }

    @Override public synchronized void close() {
        closing = true;
        animation.shutdownNow();
        if (layer != null) {
            try {
                Object tx = transaction.getConstructor().newInstance();
                try {
                    transaction.getMethod("remove", control).invoke(tx, layer);
                    transaction.getMethod("apply").invoke(tx);
                } finally { ((AutoCloseable) tx).close(); }
            } catch (Throwable ignored) {}
            try { control.getMethod("release").invoke(layer); } catch (Throwable ignored) {}
            layer = null;
        }
        if (surface != null) {
            try { surface.release(); } catch (Throwable ignored) {}
            surface = null;
        }
        if (queue != null) {
            try {
                if (queue instanceof AutoCloseable) ((AutoCloseable) queue).close();
                else queue.getClass().getMethod("destroy").invoke(queue);
            } catch (Throwable ignored) {}
            queue = null;
        }
        if (message != null) {
            message.recycle();
            message = null;
        }
        width = 0;
        height = 0;
        stack = -1;
    }
}
