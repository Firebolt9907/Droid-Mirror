import app.droidmirror.bluetooth.bridge.CatalogPushSubscriptions;
import java.util.ArrayList;
import kotlin.Unit;

public final class CatalogPushSubscriptionsTest {
    static void check(boolean value) { if (!value) throw new AssertionError(); }
    public static void main(String[] args) {
        var subscriptions = new CatalogPushSubscriptions();
        var first = new ArrayList<String>();
        var second = new ArrayList<String>();
        boolean[] valid = {true};
        subscriptions.subscribe("first", () -> valid[0], value -> { first.add(value); return Unit.INSTANCE; });
        subscriptions.publish("a"); subscriptions.publish("a");
        check(first.size() == 1);
        subscriptions.subscribe("second", () -> true, value -> { second.add(value); return Unit.INSTANCE; });
        subscriptions.publish("a");
        check(first.size() == 1 && second.size() == 1);
        // A local/legacy catalog read can scan a new revision before the broadcast handler runs.
        subscriptions.publish("b"); subscriptions.publish("b");
        check(first.size() == 2 && second.size() == 2);
        valid[0] = false; subscriptions.publish("c");
        check(first.size() == 2 && second.size() == 3);
        subscriptions.subscribe("first", () -> true, value -> { first.add(value); return Unit.INSTANCE; });
        subscriptions.publish("c");
        check(first.size() == 3 && second.size() == 3); // Reconnect gets a baseline; other Mac stays silent.
        subscriptions.remove("first"); subscriptions.remove("second");
        check(!subscriptions.active());
        System.out.println("PASS: per-session catalog baselines, duplicate suppression, local-scan invalidation, multiple peers and reconnect");
    }
}
