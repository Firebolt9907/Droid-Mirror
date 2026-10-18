package app.droidmirror.bluetooth;

public final class ClipboardSyncTest {
    private static void check(boolean condition) { if (!condition) throw new AssertionError(); }
    public static void main(String[] args) {
        check(!ClipboardTextPolicy.allowed(null));
        check(!ClipboardTextPolicy.allowed(""));
        check(ClipboardTextPolicy.allowed("a".repeat(4096)));
        check(!ClipboardTextPolicy.allowed("a".repeat(4097)));
        check(ClipboardTextPolicy.allowed("😀".repeat(1024)));
        check(!ClipboardTextPolicy.allowed("😀".repeat(1025)));
        check(ClipboardTextPolicy.allowed("\u0001".repeat(916)));
        check(!ClipboardTextPolicy.allowed("\u0001".repeat(917)));
        check(ClipboardFilePolicy.allowed(0));
        check(ClipboardFilePolicy.allowed(4_999_999));
        check(!ClipboardFilePolicy.allowed(5_000_000));
        check(!ClipboardFilePolicy.allowed(-1));
        check(ClipboardFilePolicy.nameAllowed("résumé.pdf"));
        for (String name : new String[]{"", ".", "..", "../escape", "/tmp/file", "a\\b", "a:b", "a\n"}) check(!ClipboardFilePolicy.nameAllowed(name));
        ClipboardChangeTracker state = new ClipboardChangeTracker();
        check(!state.sample("old phone clipboard"));
        check(state.sample("new copy"));
        check(!state.sample("new copy"));
        state.applied("received from Mac");
        check(!state.sample("received from Mac"));
        check(!state.sample(null)); // lock or sensitive data
        check(!state.sample("old content after unlock"));
        check(state.sample("fresh copy"));
        check(!state.sample(""));
        check(state.sample("first copy after empty clipboard"));
        state.reset();
        check(!state.sample("offline copy"));
        check(state.sample("online copy"));
        System.out.println("Android clipboard tests passed");
    }
}
