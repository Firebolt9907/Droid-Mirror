import app.droidmirror.wearprotocol.WearCommandPolicy;
import app.droidmirror.wearprotocol.WearProtocol;

public final class WearCommandPolicyTest {
    private static void check(boolean value) { if (!value) throw new AssertionError(); }
    public static void main(String[] args) {
        check(WearCommandPolicy.accepts("stop","lease","lease",100,"session","session"));
        check(WearCommandPolicy.accepts("find","lease","lease",100,"mac","mac"));
        check(!WearCommandPolicy.accepts("start","lease","lease",100,"session","session"));
        check(!WearCommandPolicy.accepts("stop","old","new",100,"session","session"));
        check(!WearCommandPolicy.accepts("stop","lease","lease",WearProtocol.LEASE_MS,"session","session"));
        check(!WearCommandPolicy.accepts("find","lease","lease",-1,"mac","mac"));
        check(!WearCommandPolicy.accepts("stop","lease","lease",100,"old-session","new-session"));
        check(!WearCommandPolicy.accepts("find","lease","lease",100,"old-mac","new-mac"));
        check(!WearCommandPolicy.accepts("stop","lease","lease",100,"",""));
        System.out.println("Wear command policy: expired leases and stale targets rejected");
    }
}
