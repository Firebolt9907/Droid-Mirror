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
        for (int flag : new int[] { Notification.FLAG_ONGOING_EVENT, Notification.FLAG_NO_CLEAR,
                Notification.FLAG_FOREGROUND_SERVICE }) {
            check(NotificationForwardingPolicy.activityEligible(chat, own, null, flag, Notification.VISIBILITY_PRIVATE));
            check(!NotificationForwardingPolicy.activityEligible(own, own, null, flag, Notification.VISIBILITY_PUBLIC));
            check(!NotificationForwardingPolicy.activityEligible(chat, own, null, flag, Notification.VISIBILITY_SECRET));
            check(!NotificationForwardingPolicy.activityEligible(chat, own, null,
                flag | Notification.FLAG_GROUP_SUMMARY, Notification.VISIBILITY_PUBLIC));
        }
        check(!NotificationForwardingPolicy.activityEligible("com.android.shell", own,
            "DroidMirror.remote-use", Notification.FLAG_ONGOING_EVENT, Notification.VISIBILITY_PRIVATE));
        check(NotificationForwardingPolicy.routine("android", Notification.CATEGORY_SYSTEM, null, false));
        check(NotificationForwardingPolicy.routine("android", null, "PHYSICAL_KEYBOARD", false));
        check(NotificationForwardingPolicy.routine("com.android.systemui", null, "virtual_keyboard", false));
        check(NotificationForwardingPolicy.routine(chat, Notification.CATEGORY_SERVICE, null, false));
        check(NotificationForwardingPolicy.routine(chat, Notification.CATEGORY_TRANSPORT, null, false));
        check(NotificationForwardingPolicy.routine(chat, null, null, true));
        for (String category : new String[] { null, Notification.CATEGORY_MESSAGE, Notification.CATEGORY_CALL,
                Notification.CATEGORY_ALARM, Notification.CATEGORY_ERROR }) {
            check(!NotificationForwardingPolicy.routine("android", category, "alerts", false));
            check(!NotificationForwardingPolicy.routine(chat, category, null, false));
        }
        check(!NotificationForwardingPolicy.routine(chat, Notification.CATEGORY_SYSTEM, "PHYSICAL_KEYBOARD", false));
        check(NotificationForwardingPolicy.media(Notification.CATEGORY_TRANSPORT, null, false));
        check(NotificationForwardingPolicy.media(null, "android.app.Notification$MediaStyle", false));
        check(NotificationForwardingPolicy.media(null, "android.app.Notification$DecoratedMediaCustomViewStyle", false));
        check(!NotificationForwardingPolicy.media(Notification.CATEGORY_CALL, "android.app.Notification$CallStyle", false));
        check(!NotificationForwardingPolicy.media(Notification.CATEGORY_SERVICE, null, false));
        System.out.println("Android notification forwarding policy tests passed");
    }
}
