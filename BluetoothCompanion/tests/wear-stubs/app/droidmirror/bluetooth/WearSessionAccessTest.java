package app.droidmirror.bluetooth;
import android.app.PendingIntent;
import android.content.Context;
public class WearSessionAccessTest {
    private static void check(boolean value) { if (!value) throw new AssertionError(); }
    public static void main(String[] args) {
        Context ctx = new Context();
        WearSessionAccess.streaming(ctx,"old"); PendingIntent old = StreamNotifications.last;
        check(!WearSessionAccess.stop("wrong")); check(old.sends == 0);
        check(WearSessionAccess.stop("old")); check(old.sends == 1);
        check(WearSessionAccess.token().equals("old")); // Requesting stop is not confirmation of shutdown.
        WearSessionAccess.streaming(ctx,"new"); PendingIntent next = StreamNotifications.last;
        WearSessionAccess.ended("old"); check(WearSessionAccess.token().equals("new"));
        check(!WearSessionAccess.stop("old")); check(next.sends == 0);
        check(WearSessionAccess.stop("new")); check(next.sends == 1);
        next.canceled = true; check(!WearSessionAccess.stop("new"));
        WearSessionAccess.ended("new"); check(!WearSessionAccess.stop("new"));
        check(WearSessionAccess.token().isEmpty());
        System.out.println("Wear privacy stop: exact-session routing, cancellation and completion tests passed");
    }
}
