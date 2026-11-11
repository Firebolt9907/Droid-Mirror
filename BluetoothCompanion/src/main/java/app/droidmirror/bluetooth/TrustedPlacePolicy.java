package app.droidmirror.bluetooth;

import java.util.HashSet;
import java.util.Set;

public final class TrustedPlacePolicy {
    private TrustedPlacePolicy() {}
    public static boolean valid(double latitude, double longitude, float radius) {
        return Double.isFinite(latitude) && Double.isFinite(longitude) && Float.isFinite(radius)
            && latitude >= -90 && latitude <= 90 && longitude >= -180 && longitude <= 180
            && radius >= 100 && radius <= 5000;
    }
    public static boolean usableFix(long ageMs, float accuracy, float radius) {
        return ageMs >= 0 && ageMs <= 120_000 && Float.isFinite(accuracy) && accuracy >= 0 && accuracy <= radius;
    }
    /** Ignore deleted/unknown fences, and never let one overlapping exit clear another place. */
    public static Set<String> transition(Set<String> inside, Set<String> registered, Set<String> events, boolean enter) {
        Set<String> next = new HashSet<>(inside);
        next.retainAll(registered);
        for (String id : events) if (registered.contains(id)) {
            if (enter) next.add(id); else next.remove(id);
        }
        return next;
    }
}
