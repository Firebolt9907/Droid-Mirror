import app.droidmirror.bluetooth.TrustedPlacePolicy;
import java.util.Set;
public final class TrustedPlacePolicyTest {
    static void check(boolean value) { if (!value) throw new AssertionError(); }
    public static void main(String[] args) {
        check(TrustedPlacePolicy.valid(0, 0, 200));
        check(TrustedPlacePolicy.valid(-90, 180, 5000));
        check(!TrustedPlacePolicy.valid(91, 0, 200));
        check(!TrustedPlacePolicy.valid(0, -181, 200));
        check(!TrustedPlacePolicy.valid(Double.NaN, 0, 200));
        check(!TrustedPlacePolicy.valid(0, 0, Float.POSITIVE_INFINITY));
        check(!TrustedPlacePolicy.valid(0, 0, 99));
        check(!TrustedPlacePolicy.valid(0, 0, 5001));
        check(TrustedPlacePolicy.usableFix(120_000, 200, 200));
        check(!TrustedPlacePolicy.usableFix(120_001, 10, 200));
        check(!TrustedPlacePolicy.usableFix(-1, 10, 200));
        check(!TrustedPlacePolicy.usableFix(0, 201, 200));
        check(!TrustedPlacePolicy.usableFix(0, Float.NaN, 200));
        Set<String> places = Set.of("home", "garden");
        Set<String> inside = TrustedPlacePolicy.transition(Set.of(), places, Set.of("home"), true);
        check(inside.equals(Set.of("home")));
        inside = TrustedPlacePolicy.transition(inside, places, Set.of("garden"), true);
        check(inside.equals(places));
        inside = TrustedPlacePolicy.transition(inside, places, Set.of("home"), false);
        check(inside.equals(Set.of("garden"))); // An overlapping exit must keep detection paused.
        inside = TrustedPlacePolicy.transition(inside, Set.of("home"), Set.of("deleted-place"), true);
        check(inside.isEmpty()); // Deleted/unknown callbacks cannot suppress detection.
        check(TrustedPlacePolicy.transition(Set.of("home"), places, Set.of("home"), true).equals(Set.of("home")));
        check(TrustedPlacePolicy.transition(Set.of("home"), places, Set.of("home"), false).isEmpty());
        System.out.println("PASS: trusted-place overlap/deletion transitions, input bounds and fresh accurate fixes");
    }
}
