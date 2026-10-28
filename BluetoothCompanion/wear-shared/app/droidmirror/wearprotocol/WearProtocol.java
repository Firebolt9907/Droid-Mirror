package app.droidmirror.wearprotocol;

/** Live messages only: commands and session state are never queued as DataItems. */
public final class WearProtocol {
    public static final String STATE = "/droidmirror/watch/state";
    public static final String REQUEST = "/droidmirror/watch/request";
    public static final String COMMAND = "/droidmirror/watch/command";
    public static final String RESULT = "/droidmirror/watch/result";
    public static final String PHONE_CAPABILITY = "droidmirror_phone";
    public static final long LEASE_MS = 35_000;
    public static final int MAX_BYTES = 4096;
    private WearProtocol() {}
}
