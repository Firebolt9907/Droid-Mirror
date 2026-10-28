package app.droidmirror.wearprotocol;

/** A watch action can only address the state recently advertised by this phone process. */
public final class WearCommandPolicy {
    public static boolean accepts(String action, String lease, String currentLease, long leaseAge,
                                  String target, String currentTarget) {
        return ("stop".equals(action) || "find".equals(action))
            && lease != null && !lease.isEmpty() && lease.equals(currentLease)
            && leaseAge >= 0 && leaseAge < WearProtocol.LEASE_MS
            && target != null && !target.isEmpty() && target.equals(currentTarget);
    }
    private WearCommandPolicy() {}
}
