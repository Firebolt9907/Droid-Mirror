package app.droidmirror.bluetooth;

import android.content.Context;
import android.content.Intent;
import android.content.IntentFilter;
import android.graphics.Bitmap;
import android.graphics.Canvas;
import android.graphics.Color;
import android.graphics.Paint;
import android.graphics.Path;
import android.graphics.Typeface;
import android.os.BatteryManager;
import android.text.Layout;
import android.text.StaticLayout;
import android.text.TextPaint;
import android.text.TextUtils;
import android.text.format.DateFormat;

import java.io.ByteArrayOutputStream;
import java.text.SimpleDateFormat;
import java.util.Date;
import java.util.Locale;

/** Fonts stay in the initialized app. The shell receives only bounded bitmap pixels. */
final class BlackoutMessage {
    private BlackoutMessage() {}

    static final class State {
        final String time, date, battery;
        final boolean charging;

        State(String time, String date, String battery, boolean charging) {
            this.time = time;
            this.date = date;
            this.battery = battery;
            this.charging = charging;
        }

        boolean matches(State other) {
            return other != null
                && time.equals(other.time)
                && date.equals(other.date)
                && battery.equals(other.battery)
                && charging == other.charging;
        }
    }

    static State read(Context context) {
        Date now = new Date();

        String time = new SimpleDateFormat(
            DateFormat.is24HourFormat(context) ? "HH:mm" : "h:mm",
            Locale.getDefault()
        ).format(now);

        String date = new SimpleDateFormat(
            "EEE, MMM d",
            Locale.getDefault()
        ).format(now);

        Intent battery = context.registerReceiver(
            null,
            new IntentFilter(Intent.ACTION_BATTERY_CHANGED)
        );

        int level = battery == null
            ? -1
            : battery.getIntExtra(BatteryManager.EXTRA_LEVEL, -1);

        int scale = battery == null
            ? 0
            : battery.getIntExtra(BatteryManager.EXTRA_SCALE, 0);

        int status = battery == null
            ? -1
            : battery.getIntExtra(BatteryManager.EXTRA_STATUS, -1);

        boolean charging =
            status == BatteryManager.BATTERY_STATUS_CHARGING ||
            status == BatteryManager.BATTERY_STATUS_FULL;

        String percentage = level >= 0 && scale > 0
            ? Math.round(Math.min(1f, level / (float) scale) * 100) + "%"
            : "";

        return new State(time, date, percentage, charging);
    }

    static byte[] create(State state, String computerName) {
        // Atlas: clock/date [0,350), activity [360,660), battery [680,800).
        // Separate regions let the shell lay out either orientation without fonts.
        Bitmap bitmap = Bitmap.createBitmap(900, 800, Bitmap.Config.ARGB_8888);

        try {
            Canvas canvas = new Canvas(bitmap);
            canvas.drawColor(Color.BLACK);

            Paint paint = new Paint(Paint.ANTI_ALIAS_FLAG);
            paint.setColor(Color.rgb(84, 84, 84));
            paint.setTextAlign(Paint.Align.CENTER);
            paint.setTypeface(Typeface.create("sans-serif", Typeface.BOLD));
            paint.setTextSize(280);

            float clockWidth = paint.measureText(state.time);
            if (clockWidth > 820) {
                paint.setTextSize(280 * 820 / clockWidth);
            }

            canvas.drawText(state.time, 450, 230, paint);

            // Larger date with breathing room below the clock.
            paint.setTypeface(Typeface.create("sans-serif", Typeface.NORMAL));
            paint.setTextSize(56);
            paint.setColor(Color.rgb(90, 90, 90));
            canvas.drawText(state.date, 450, 322, paint);

            // Activity card text.
            TextPaint text = new TextPaint(Paint.ANTI_ALIAS_FLAG);
            text.setColor(Color.rgb(90, 90, 90));
            text.setTypeface(Typeface.create("sans-serif", Typeface.NORMAL));
            text.setTextSize(40);

            String name = computerName == null
                ? ""
                : computerName.replaceAll("[\\p{Cntrl}\\p{Cf}]", " ").trim();

            if (name.isEmpty()) {
                name = "your Mac";
            }

            if (name.length() > 160) {
                name = name.substring(0, 160);
            }

            String message = "This phone is being used from “" + name + "”.";

            StaticLayout lines = StaticLayout.Builder.obtain(
                    message, 0, message.length(), text, 660
                )
                .setAlignment(Layout.Alignment.ALIGN_NORMAL)
                .setIncludePad(false)
                .setMaxLines(3)
                .setEllipsize(TextUtils.TruncateAt.END)
                .setLineSpacing(4, 1)
                .build();

            float cardBottom = 384 + lines.getHeight() + 26;

            // Position the activity card 35 px above the battery region.
            canvas.save();
            canvas.translate(0, BlackoutText.BATTERY_TOP - 35 - cardBottom);

            // Outlined activity capsule.
            paint.setStyle(Paint.Style.STROKE);
            paint.setStrokeWidth(2.5f);
            paint.setColor(Color.rgb(90, 90, 90));

            canvas.drawRoundRect(
                14, 294, 886, cardBottom, 62, 62, paint
            );

            // Phone and pointer glyph.
            canvas.save();
            canvas.translate(0, (294 + cardBottom) / 2 - 434.5f);

            paint.setStrokeWidth(5);
            canvas.drawRoundRect(64, 384, 110, 464, 7, 7, paint);

            paint.setStyle(Paint.Style.FILL);

            for (int row = 0; row < 3; row++) {
                for (int column = 0; column < 3; column++) {
                    canvas.drawRoundRect(
                        73 + column * 10,
                        395 + row * 11,
                        79 + column * 10,
                        402 + row * 11,
                        1, 1, paint
                    );
                }
            }

            Path pointer = new Path();
            pointer.moveTo(94, 430);
            pointer.lineTo(126, 460);
            pointer.lineTo(113, 463);
            pointer.lineTo(122, 481);
            pointer.lineTo(113, 485);
            pointer.lineTo(104, 467);
            pointer.lineTo(94, 477);
            pointer.close();

            paint.setColor(Color.BLACK);
            paint.setStyle(Paint.Style.STROKE);
            paint.setStrokeWidth(8);
            canvas.drawPath(pointer, paint);

            paint.setStyle(Paint.Style.FILL);
            paint.setColor(Color.rgb(90, 90, 90));
            canvas.drawPath(pointer, paint);

            canvas.restore();

            // Activity title.
            text.setTypeface(Typeface.create("sans-serif-medium", Typeface.NORMAL));
            text.setTextSize(44);
            canvas.drawText("Phone in Use", 166, 362, text);

            // Activity description.
            text.setTypeface(Typeface.create("sans-serif", Typeface.NORMAL));
            text.setTextSize(40);

            canvas.save();
            canvas.translate(166, 384);
            lines.draw(canvas);
            canvas.restore();

            canvas.restore();

            // Battery percentage and charging indicator.
            paint.setStyle(Paint.Style.FILL);
            paint.setTypeface(Typeface.create("sans-serif-medium", Typeface.NORMAL));
            paint.setTextAlign(Paint.Align.CENTER);
            paint.setColor(Color.rgb(76, 76, 76));
            paint.setTextSize(42);

            float batteryTextWidth = paint.measureText(state.battery);

            if (state.charging && !state.battery.isEmpty()) {
                // Center the lightning bolt and battery text as a group.
                float boltWidth = 22;
                float gap = 12;
                float totalWidth = boltWidth + gap + batteryTextWidth;
                float startX = 450 - totalWidth / 2;

                Path bolt = new Path();
                bolt.moveTo(startX + 14, 725);
                bolt.lineTo(startX + 2, 750);
                bolt.lineTo(startX + 12, 750);
                bolt.lineTo(startX + 7, 773);
                bolt.lineTo(startX + 24, 744);
                bolt.lineTo(startX + 14, 744);
                bolt.close();

                canvas.drawPath(bolt, paint);

                paint.setTextAlign(Paint.Align.LEFT);
                canvas.drawText(
                    state.battery,
                    startX + boltWidth + gap,
                    756,
                    paint
                );
            } else {
                canvas.drawText(state.battery, 450, 756, paint);
            }

            ByteArrayOutputStream output = new ByteArrayOutputStream();

            if (!bitmap.compress(Bitmap.CompressFormat.PNG, 100, output)) {
                throw new IllegalStateException(
                    "Could not prepare mirroring message"
                );
            }

            byte[] bytes = output.toByteArray();

            if (bytes.length > 128 * 1024) {
                throw new IllegalStateException("Mirroring message too large");
            }

            return bytes;
        } finally {
            bitmap.recycle();
        }
    }
}
