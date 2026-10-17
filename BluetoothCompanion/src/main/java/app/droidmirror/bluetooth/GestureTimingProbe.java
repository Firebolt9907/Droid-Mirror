package app.droidmirror.bluetooth;

import android.view.MotionEvent;
import android.view.VelocityTracker;
import com.genymobile.scrcpy.control.ControlMessage;
import com.genymobile.scrcpy.control.ControlMessageReader;
import java.io.*;

/** Exercises Android's real velocity tracker without injecting any input. */
public final class GestureTimingProbe {
    public static void main(String[] args) throws Exception {
        DataInputStream input = new DataInputStream(System.in);
        ByteArrayOutputStream payload = new ByteArrayOutputStream();
        while (true) {
            int type = input.read(); if (type == -1) break;
            int length = input.readInt();
            if (type != 0 || length <= 0 || length > 4096) throw new IOException("Invalid test fixture");
            byte[] bytes = new byte[length]; input.readFully(bytes); payload.write(bytes);
        }
        ControlMessageReader reader = new ControlMessageReader(new ByteArrayInputStream(payload.toByteArray()));
        VelocityTracker tracker = VelocityTracker.obtain();
        long start = -1, last = -1, maximumGap = 0; int moves = 0;
        try {
            while (true) {
                ControlMessage message;
                try { message = reader.read(); } catch (EOFException done) { break; }
                if (message.getType() != ControlMessage.TYPE_INJECT_TOUCH_EVENT) throw new AssertionError("Unexpected command");
                long time = message.getEventTime();
                if (start < 0) start = time;
                if (last >= 0) maximumGap = Math.max(maximumGap, time - last);
                last = time;
                MotionEvent event = MotionEvent.obtain(start, time, message.getAction(),
                    message.getPosition().getPoint().getX(), message.getPosition().getPoint().getY(), 0);
                tracker.addMovement(event); event.recycle();
                if (message.getAction() == MotionEvent.ACTION_MOVE) ++moves;
            }
            tracker.computeCurrentVelocity(1000);
            float velocity = tracker.getYVelocity();
            if (last - start != 101 || moves < 5 || maximumGap > 33 || velocity > -6000) {
                System.err.println("Gesture velocity lost: " + velocity + ", moves=" + moves + ", gap=" + maximumGap);
                System.exit(2); return;
            }
            System.out.println("Android VelocityTracker PASS: durationMs=" + (last-start) + " moves=" + moves
                + " maxSourceGapMs=" + maximumGap + " velocityY=" + velocity);
        } finally { tracker.recycle(); }
    }
}
