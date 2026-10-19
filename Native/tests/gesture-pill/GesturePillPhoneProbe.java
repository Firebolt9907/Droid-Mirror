package com.genymobile.scrcpy.control;

import com.genymobile.scrcpy.Options;
import com.genymobile.scrcpy.Workarounds;
import com.genymobile.scrcpy.display.DisplayInfo;
import com.genymobile.scrcpy.model.Position;
import com.genymobile.scrcpy.wrappers.ServiceManager;

import android.os.Looper;
import android.view.MotionEvent;

import java.lang.reflect.Method;

/** Read-only on-device check: no event injection and no settings changes. */
public final class GesturePillPhoneProbe {
    public static void main(String[] args) throws Exception {
        Looper.prepareMainLooper();
        Workarounds.apply();
        Options options = Options.parse("5.0", "clipboard_autosync=false", "power_on=false", "cleanup=false");
        Controller controller = new Controller(null, null, options);
        Method modeMethod = Controller.class.getDeclaredMethod("navigationMode");
        modeMethod.setAccessible(true);
        int mode = (Integer) modeMethod.invoke(controller);
        DisplayInfo info = ServiceManager.getDisplayManager().getDisplayInfo(0);
        int width = info.getSize().getWidth();
        int height = info.getSize().getHeight();
        Method hit = Controller.class.getDeclaredMethod("isPillDown", ControlMessage.class);
        hit.setAccessible(true);
        int[] xs = {width / 2, width / 2, 0};
        int[] ys = {height - (int) (4 * info.getDpi() / 160f), height - (int) (28 * info.getDpi() / 160f), height - 1};
        for (int i = 0; i < xs.length; ++i) {
            ControlMessage down = ControlMessage.createInjectTouchEvent(MotionEvent.ACTION_DOWN, -1,
                    new Position(xs[i], ys[i], width, height), 1, MotionEvent.BUTTON_PRIMARY, MotionEvent.BUTTON_PRIMARY);
            boolean found = (Boolean) hit.invoke(controller, down);
            boolean expected = mode == 2 && i == 0;
            if (found != expected) {
                throw new AssertionError("Hit test " + i + ": " + found + " expected " + expected);
            }
        }
        controller.stop();
        System.out.println("PASS: runtime navigation mode=" + mode + ", display=" + width + "x" + height
                + ", dpi=" + info.getDpi() + "; pill center accepted only in gesture mode; content and edges excluded");
    }
}
