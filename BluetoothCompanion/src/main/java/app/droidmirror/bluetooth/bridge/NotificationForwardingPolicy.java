package app.droidmirror.bluetooth.bridge;

import android.app.Notification;

/** Filter both initial snapshots and live updates using Android's own metadata. */
public final class NotificationForwardingPolicy {
    public static boolean eligible(String sourcePackage, String ownPackage, int flags, int visibility) {
        return eligible(sourcePackage, ownPackage, null, flags, visibility);
    }

    public static boolean remoteUseAudit(String sourcePackage, String tag) {
        return "com.android.shell".equals(sourcePackage) && "DroidMirror.remote-use".equals(tag);
    }

    public static boolean eligible(String sourcePackage, String ownPackage, String tag, int flags, int visibility) {
        int excluded = Notification.FLAG_ONGOING_EVENT | Notification.FLAG_NO_CLEAR
            | Notification.FLAG_FOREGROUND_SERVICE | Notification.FLAG_GROUP_SUMMARY;
        return !ownPackage.equals(sourcePackage) && !remoteUseAudit(sourcePackage, tag) && (flags & excluded) == 0
            && visibility != Notification.VISIBILITY_SECRET;
    }

    public static boolean routine(String sourcePackage, String category, String channel, boolean progress) {
        if (Notification.CATEGORY_SERVICE.equals(category) || Notification.CATEGORY_TRANSPORT.equals(category)
                || progress) return true;
        boolean system = "android".equals(sourcePackage) || "com.android.systemui".equals(sourcePackage);
        String channelName = channel == null ? "" : channel.toLowerCase(java.util.Locale.ROOT);
        return system && (Notification.CATEGORY_SYSTEM.equals(category)
            || channelName.equals("physical_keyboard") || channelName.equals("virtual_keyboard"));
    }

    private NotificationForwardingPolicy() {}
}
