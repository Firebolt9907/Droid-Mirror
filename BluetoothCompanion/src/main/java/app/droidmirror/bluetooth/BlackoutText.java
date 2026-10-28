package app.droidmirror.bluetooth;

import android.graphics.Bitmap;
import android.graphics.Canvas;
import android.graphics.Paint;
import android.graphics.Rect;
import android.graphics.RectF;

/** Shell rendering uses bitmap regions, never the shell's uninitialized fonts. */
final class BlackoutText {
    static final int CLOCK_BOTTOM = 350;
    static final int ACTIVITY_TOP = 360, ACTIVITY_BOTTOM = 660;
    static final int BATTERY_TOP = 680;
    private BlackoutText() {}
    static void draw(Canvas canvas, int width, int height, Bitmap message) {
        draw(canvas, width, height, message, 1, 1);
    }
    static float ease(float progress) {
        float t = Math.max(0, Math.min(1, progress));
        return 1 - (1 - t) * (1 - t) * (1 - t);
    }
    static float easeIn(float progress) {
        float t = Math.max(0, Math.min(1, progress));
        return t * t * t;
    }
    static void draw(Canvas canvas, int width, int height, Bitmap message, float opacity, float entrance) {
        float unit = Math.min(width * 0.9f / 900, height / 1100f);
        float left = (width - 900 * unit) / 2;
        Paint paint = new Paint(Paint.FILTER_BITMAP_FLAG);
        paint.setAlpha(Math.round(255 * Math.max(0, Math.min(1, opacity))));
        // Small, discrete shifts avoid keeping the outlines on identical pixels.
        int phase = (int) ((System.currentTimeMillis() / 60000) % 4);
        float dx = (phase == 0 ? -3 : phase == 2 ? 3 : 0) * unit;
        float dy = (phase == 1 ? -3 : phase == 3 ? 3 : 0) * unit;
        canvas.save(); canvas.translate(dx, dy);
        region(canvas, message, paint, 0, CLOCK_BOTTOM, left, height * 0.22f - 155 * unit, unit);
        float batteryTop = height * 0.95f - 60 * unit;
        // The card outline ends at atlas row 645, 15 px before its region ends.
        // Leave 35 px between that outline and the battery region on the display.
        float activityTop = batteryTop - (20 + ACTIVITY_BOTTOM - ACTIVITY_TOP) * unit;
        float scaleProgress = ease(entrance);
        float translationProgress = easeIn(entrance);
        canvas.save();
        // Reveal from the lower edge without sliding over the battery label.
        canvas.clipRect(0, 0, width, batteryTop - 20 * unit);
        canvas.translate(0, (height - activityTop) * (1 - translationProgress));
        float scale = 0.86f + 0.14f * scaleProgress;
        canvas.scale(scale, scale, width / 2f, activityTop + (ACTIVITY_BOTTOM - ACTIVITY_TOP) * unit / 2);
        paint.setAlpha(Math.round(255 * Math.max(0, Math.min(1, opacity)) * scaleProgress));
        region(canvas, message, paint, ACTIVITY_TOP, ACTIVITY_BOTTOM, left, activityTop, unit);
        canvas.restore();
        paint.setAlpha(Math.round(255 * Math.max(0, Math.min(1, opacity))));
        region(canvas, message, paint, BATTERY_TOP, 800, left, batteryTop, unit);
        canvas.restore();
    }
    private static void region(Canvas canvas, Bitmap bitmap, Paint paint, int top, int bottom,
                               float left, float y, float unit) {
        canvas.drawBitmap(bitmap, new Rect(0, top, 900, bottom),
            new RectF(left, y, left + 900 * unit, y + (bottom - top) * unit), paint);
    }
}
