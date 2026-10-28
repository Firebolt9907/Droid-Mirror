package app.droidmirror.bluetooth;

import android.app.Instrumentation;
import android.graphics.Bitmap;
import android.graphics.BitmapFactory;
import android.graphics.Canvas;
import android.graphics.Color;
import android.os.Bundle;
import java.io.File;
import java.io.FileOutputStream;

/** Renders real app fonts; the separate shell test checks font-free composition. */
public final class BlackoutAppearanceTest extends Instrumentation {
    @Override public void onCreate(Bundle arguments) { super.onCreate(arguments); start(); }
    @Override public void onStart() {
        Bundle result = new Bundle();
        try {
            BlackoutMessage.State original = new BlackoutMessage.State("4:05", "Wed, Oct 21", "48%", true);
            if (!original.matches(new BlackoutMessage.State("4:05", "Wed, Oct 21", "48%", true))
                    || original.matches(new BlackoutMessage.State("4:06", "Wed, Oct 21", "48%", true))
                    || original.matches(new BlackoutMessage.State("4:05", "Wed, Oct 21", "49%", true)))
                throw new AssertionError("Clock and battery changes must refresh the AOD");
            if (original.matches(new BlackoutMessage.State("4:05", "Thu, Oct 22", "48%", true))
                    || original.matches(new BlackoutMessage.State("4:05", "Wed, Oct 21", "48%", false)))
                throw new AssertionError("Date/charging changes must refresh the AOD");
            float prior = -1;
            for (int i = 0; i <= 100; i++) {
                float eased = BlackoutText.ease(i / 100f);
                if (eased < prior || eased < 0 || eased > 1) throw new AssertionError("Non-monotonic entrance curve");
                prior = eased;
            }
            if (BlackoutText.ease(0) != 0 || BlackoutText.ease(1) != 1)
                throw new AssertionError("Invalid motion endpoints");
            if (BlackoutText.easeIn(0) != 0 || BlackoutText.easeIn(1) != 1
                    || BlackoutText.easeIn(.5f) != .125f || BlackoutText.ease(.5f) != .875f)
                throw new AssertionError("Scale must ease out and translation must ease in over shared progress");
            byte[] normal = BlackoutMessage.create(original, "Rishu’s MacBook Pro");
            // Exercise the actual guard validator, including malformed refresh data.
            java.lang.reflect.Method decode = BlackoutOverlay.class.getDeclaredMethod("decode", byte[].class);
            decode.setAccessible(true);
            ((Bitmap) decode.invoke(null, (Object) normal)).recycle();
            try {
                decode.invoke(null, (Object) new byte[]{1, 2, 3});
                throw new AssertionError("Guard accepted a malformed atlas");
            } catch (java.lang.reflect.InvocationTargetException expected) {
                if (!(expected.getCause() instanceof IllegalArgumentException)) throw expected;
            }
            motion(normal, 1080, 2400);
            motion(normal, 2400, 1080);
            render(normal, 1080, 2400, "blackout-aod-portrait.png");
            render(normal, 2400, 1080, "blackout-aod-landscape.png");
            render(BlackoutMessage.create(new BlackoutMessage.State("23:59", "Wed, Oct 21", "100%", true),
                "Very long Mac name that must wrap and eventually truncate without escaping the activity card ".repeat(4)),
                1080, 2400, "blackout-aod-long-name.png");
            render(BlackoutMessage.create(new BlackoutMessage.State("12:00", "Wed, Oct 21", "", true), null),
                720, 1280, "blackout-aod-fallback.png");
            BlackoutMessage.State live = BlackoutMessage.read(getTargetContext());
            if (live.time.isEmpty() || !live.battery.matches("[0-9]{1,3}%"))
                throw new AssertionError("Live time/battery missing");
            result.putString("stream", "AOD rendering, 12/24h, live state, long names, fallback and bitmap bounds passed\n");
            finish(-1, result);
        } catch (Throwable failure) {
            result.putString("stream", android.util.Log.getStackTraceString(failure));
            finish(0, result);
        }
    }
    private void motion(byte[] png, int width, int height) throws Exception {
        Bitmap atlas = BitmapFactory.decodeByteArray(png, 0, png.length);
        Bitmap screen = Bitmap.createBitmap(width, height, Bitmap.Config.ARGB_8888);
        try {
            Canvas canvas = new Canvas(screen);
            float[] steps = {0, .1f, .25f, .5f, .75f, 1};
            for (float progress : steps) {
                canvas.drawColor(Color.BLACK);
                BlackoutText.draw(canvas, width, height, atlas, BlackoutText.ease(progress), progress);
                boolean visible = false;
                for (int y = 0; y < height; y++) for (int x = 0; x < width; x++) {
                    int pixel = screen.getPixel(x, y);
                    if (Color.alpha(pixel) != 255) throw new AssertionError("Fade exposed the underlying screen");
                    if (Color.red(pixel) > 0) visible = true;
                    float unit = Math.min(width * .9f / 900, height / 1100f);
                    if (y >= height * .95f - 60 * unit && (x < width * .3f || x > width * .7f)
                            && pixel != Color.BLACK) throw new AssertionError("Moving card crossed the battery region");
                }
                if (progress == 0 && visible) throw new AssertionError("Entrance did not begin on black");
                if (progress == 1 && !visible) throw new AssertionError("Entrance did not reveal content");
                if (width < height) {
                    try (FileOutputStream output = new FileOutputStream(new File(getTargetContext().getFilesDir(),
                            "blackout-motion-" + Math.round(progress * 100) + ".png"))) {
                        screen.compress(Bitmap.CompressFormat.PNG, 100, output);
                    }
                }
            }
            canvas.drawColor(Color.BLACK);
            BlackoutText.draw(canvas, width, height, atlas, 0, 1);
            for (int y = 0; y < height; y++) for (int x = 0; x < width; x++)
                if (screen.getPixel(x, y) != Color.BLACK) throw new AssertionError("Exit did not end on opaque black");
        } finally { atlas.recycle(); screen.recycle(); }
    }
    private void render(byte[] png, int width, int height, String file) throws Exception {
        if (png.length > 128 * 1024) throw new AssertionError("Bitmap exceeds Binder payload cap");
        Bitmap message = BitmapFactory.decodeByteArray(png, 0, png.length);
        if (message == null || message.getWidth() != 900 || message.getHeight() != 800)
            throw new AssertionError("Atlas dimensions disagree with guard");
        Bitmap screen = Bitmap.createBitmap(width, height, Bitmap.Config.ARGB_8888);
        try {
            Canvas canvas = new Canvas(screen); canvas.drawColor(Color.BLACK);
            BlackoutText.draw(canvas, width, height, message);
            // Sample the bottom of the card outline: the previous crop lost it.
            float unit = Math.min(width * .9f / 900, height / 1100f);
            float batteryTop = height * .95f - 60 * unit;
            int cardY = Math.round(batteryTop - 35 * unit);
            boolean outline = false;
            for (int y = cardY - 6; y <= cardY + 6; y++)
                if (Color.red(screen.getPixel(width / 2, y)) > 0) outline = true;
            if (!outline) throw new AssertionError("Activity bottom border clipped");
            int datePixels = 0;
            for (int y = 260; y < BlackoutText.CLOCK_BOTTOM; y++)
                for (int x = 0; x < 900; x++) if (Color.red(message.getPixel(x, y)) > 0) datePixels++;
            if (datePixels < 50) throw new AssertionError("Date missing from clock region");
            int clock = 0, activity = 0, battery = 0;
            for (int y = 0; y < height; y++) for (int x = 0; x < width; x++) {
                int pixel = screen.getPixel(x, y), grey = Color.red(pixel);
                if (Color.alpha(pixel) != 255 || grey != Color.green(pixel) || grey != Color.blue(pixel) || grey > 90)
                    throw new AssertionError("Expected opaque subdued grey on black");
                if (grey == 0) continue;
                // Allow the intentional +/-3 atlas-pixel burn-in shift plus filtering.
                if (x < width * .025 - 4 * unit || x > width * .975 + 4 * unit
                        || y < height * .04 - 4 * unit || y > height * .98 + 4 * unit)
                    throw new AssertionError("Content outside safe display area");
                if (y < height * .4) clock++;
                else if (y < batteryTop - 10 * unit) activity++;
                else battery++;
            }
            if (clock < 100 || activity < 100 || (!file.contains("fallback") && battery < 20))
                throw new AssertionError("AOD component missing");
            try (FileOutputStream output = new FileOutputStream(new File(getTargetContext().getFilesDir(), file))) {
                screen.compress(Bitmap.CompressFormat.PNG, 100, output);
            }
        } finally { message.recycle(); screen.recycle(); }
    }
}
