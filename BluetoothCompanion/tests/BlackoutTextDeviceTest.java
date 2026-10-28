package app.droidmirror.bluetooth;

import android.graphics.Bitmap;
import android.graphics.Canvas;
import android.graphics.Color;
import android.graphics.Paint;
import java.util.concurrent.atomic.AtomicReference;

/** Run in app_process, never instrumentation: app binding masks the missing-font bug. */
public final class BlackoutTextDeviceTest {
    public static void main(String[] args) throws Exception {

        AtomicReference<Throwable> failure = new AtomicReference<>();
        Thread binder = new Thread(() -> {
            try {
                check(1080, 2400);
                check(2400, 1080);
                check(1080, 2400); // Repeated draws must retain initialized native fonts.
            } catch (Throwable error) { failure.set(error); }
        }, "blackout-binder-test");
        binder.start(); binder.join();
        if (failure.get() != null) throw new AssertionError("Shell text rendering failed", failure.get());
        System.out.println("BlackoutText: font-independent shell bitmap rendering passed in portrait, landscape and repeated draws");
    }
    private static void check(int width, int height) throws Exception {
        Bitmap bitmap = Bitmap.createBitmap(width, height, Bitmap.Config.ARGB_8888);
        try {
            Canvas canvas = new Canvas(bitmap);
            canvas.drawColor(Color.BLACK);
            Bitmap message = Bitmap.createBitmap(900, 800, Bitmap.Config.ARGB_8888);
            try {
                Canvas fixture = new Canvas(message);
                fixture.drawColor(Color.BLACK);
                Paint grey = new Paint(); grey.setColor(Color.rgb(128, 128, 128));
                fixture.drawRect(250, 60, 650, 210, grey);
                fixture.drawRect(330, 270, 570, 290, grey);
                fixture.drawRect(30, 400, 870, 648, grey);
                fixture.drawRect(380, 715, 520, 756, grey);
                BlackoutText.draw(canvas, width, height, message);
            } finally { message.recycle(); }
            int grey = 0;
            for (int y = 0; y < height; y++) {
                for (int x = 0; x < width; x++) {
                    int pixel = bitmap.getPixel(x, y);
                    if (pixel == Color.BLACK) continue;
                    if (Color.red(pixel) != Color.green(pixel) || Color.green(pixel) != Color.blue(pixel)
                        || Color.red(pixel) > 128 || Color.alpha(pixel) != 255)
                        throw new AssertionError("Expected opaque grey text on black");
                    if (x < width / 40 || x > width * 39 / 40 || y < height / 25 || y > height * 49 / 50)
                        throw new AssertionError("AOD content outside safe display area");
                    grey++;
                }
            }
            if (grey < 100) throw new AssertionError("Mirroring message missing");
        } finally { bitmap.recycle(); }
    }
}
