import android.app.Notification;
import app.droidmirror.bluetooth.bridge.NotificationForwardingPolicy;

public final class NotificationForwardingPolicyTest {
    private static void check(boolean condition) {
        if (!condition) throw new AssertionError("Notification forwarding policy regression");
    }
    public static void main(String[] args) {
        String own = "app.droidmirror.bluetooth", chat = "com.example.chat";
        check(NotificationForwardingPolicy.eligible(chat, own, 0, Notification.VISIBILITY_PRIVATE));
        check(NotificationForwardingPolicy.eligible(chat, own, Notification.FLAG_AUTO_CANCEL, Notification.VISIBILITY_PUBLIC));
        check(!NotificationForwardingPolicy.eligible(own, own, 0, Notification.VISIBILITY_PUBLIC));
        check(!NotificationForwardingPolicy.eligible(chat, own, 0, Notification.VISIBILITY_SECRET));
        check(!NotificationForwardingPolicy.eligible("com.android.shell", own, "DroidMirror.remote-use",
            0, Notification.VISIBILITY_PRIVATE));
        check(NotificationForwardingPolicy.eligible("com.android.shell", own, "other-shell-notification",
            0, Notification.VISIBILITY_PRIVATE));
        check(NotificationForwardingPolicy.eligible(chat, own, "DroidMirror.remote-use",
            0, Notification.VISIBILITY_PRIVATE));
        for (int flag : new int[] { Notification.FLAG_ONGOING_EVENT, Notification.FLAG_NO_CLEAR,
                Notification.FLAG_FOREGROUND_SERVICE, Notification.FLAG_GROUP_SUMMARY }) {
            check(!NotificationForwardingPolicy.eligible(chat, own, flag, Notification.VISIBILITY_PUBLIC));
            check(!NotificationForwardingPolicy.eligible(chat, own, flag | Notification.FLAG_AUTO_CANCEL,
                Notification.VISIBILITY_PRIVATE));
        }
        System.out.println("Android notification forwarding policy tests passed");
    }
}
