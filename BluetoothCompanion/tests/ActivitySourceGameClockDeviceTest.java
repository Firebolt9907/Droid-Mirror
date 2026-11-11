import android.content.Context;
import android.os.Handler;
import android.os.Looper;
import android.os.SystemClock;
import app.droidmirror.bluetooth.bridge.ActivitySourceGameClock;
import kotlin.Unit;

/** Isolated app_process test: no APK installation, window, overlay, or active service replacement. */
public final class ActivitySourceGameClockDeviceTest {
    static int ticks;
    static void check(boolean ok, String why) { if(!ok) throw new AssertionError(why); }
    public static void main(String[] args) throws Exception {
        Looper.prepareMainLooper();
        Object thread=Class.forName("android.app.ActivityThread").getMethod("systemMain").invoke(null);
        Context context=(Context)thread.getClass().getMethod("getSystemContext").invoke(thread);
        context.setTheme(android.R.style.Theme_DeviceDefault);
        Handler ui=new Handler(Looper.getMainLooper());
        ActivitySourceGameClock clock=new ActivitySourceGameClock(context,null);
        clock.setCountDown(true); clock.setBase(SystemClock.elapsedRealtime()+9000); clock.setText("00:09");
        clock.observe(text -> { ticks++; return Unit.INSTANCE; });
        ui.postDelayed(() -> {
            check(ticks==0 && clock.getText().toString().equals("00:09"),"Observer started a paused source clock");
            clock.start(); // Simulates the source's own RemoteViews start command.
            ui.postDelayed(() -> {
                check(ticks>=2 && !clock.getText().toString().equals("00:09"),"Source-owned running clock failed to tick");
                clock.stop(); clock.setText("00:05"); // Simulates a paused source update.
                int stopped=ticks;
                ui.postDelayed(() -> {
                    check(ticks==stopped && clock.getText().toString().equals("00:05"),"Paused clock kept counting");
                    clock.start();
                    clock.observe(null);
                    int detached=ticks;
                    ui.postDelayed(() -> {
                        check(ticks==detached,"Released clock still emitted ticks");
                        System.out.println("PASS: actual Android Chronometer: paused remains paused, source start ticks, source stop freezes, observer cleanup stops callbacks");
                        System.exit(0);
                    },1200);
                },1200);
            },1400);
        },1200);
        Looper.loop();
    }
}
