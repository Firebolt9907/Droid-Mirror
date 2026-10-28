package app.droidmirror.bluetooth;

import android.graphics.Bitmap;
import android.os.SystemClock;
import android.view.InputDevice;
import android.view.InputEvent;
import android.view.MotionEvent;
import java.io.ByteArrayOutputStream;

/** Run as shell on an unlocked phone with an ordinary app visible, outside mirroring. */
public final class BlackoutInputDeviceTest {
    private static boolean touch(int action, long down) throws Exception {
        Class<?> manager;
        try { manager = Class.forName("android.hardware.input.InputManagerGlobal"); }
        catch (ClassNotFoundException older) { manager = Class.forName("android.hardware.input.InputManager"); }
        Object instance = manager.getMethod("getInstance").invoke(null);
        MotionEvent event = MotionEvent.obtain(down, SystemClock.uptimeMillis(), action, 100, 300, 0);
        event.setSource(InputDevice.SOURCE_TOUCHSCREEN);
        try {
            // WAIT_FOR_FINISH exposes input-policy rejection instead of only queueing.
            return (Boolean) manager.getMethod("injectInputEvent", InputEvent.class, int.class)
                .invoke(instance, event, 2);
        } finally { event.recycle(); }
    }
    public static void main(String[] args) throws Exception {
        Bitmap bitmap = Bitmap.createBitmap(900, 800, Bitmap.Config.ARGB_8888);
        ByteArrayOutputStream bytes = new ByteArrayOutputStream();
        bitmap.compress(Bitmap.CompressFormat.PNG, 100, bytes);
        bitmap.recycle();
        try (BlackoutOverlay overlay = new BlackoutOverlay(bytes.toByteArray())) {
            overlay.update();
            System.out.println("Overlay shown; holding for 5 seconds before the test tap");
            Thread.sleep(5000); // Allow visual confirmation and input-window publication.
            long down = SystemClock.uptimeMillis();
            boolean accepted = touch(MotionEvent.ACTION_DOWN, down);
            boolean released = touch(MotionEvent.ACTION_UP, down);
            System.out.println("Test tap sent; keeping overlay visible for another 5 seconds");
            Thread.sleep(5000);
            if (!accepted || !released) throw new AssertionError("Blackout rejected injected touch: " + accepted + "/" + released);
            System.out.println("PASS: injected DOWN/UP accepted while blackout layer was requested; confirm physical coverage separately");
        }
    }
}
