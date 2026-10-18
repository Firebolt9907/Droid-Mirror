import app.droidmirror.bluetooth.SharedLink;

public final class SharedLinkTest {
    private static void equal(String input, String expected) {
        if (!java.util.Objects.equals(SharedLink.extract(input), expected)) throw new AssertionError(input);
    }
    public static void main(String[] args) {
        equal("https://example.com/a?q=one&b=two#fragment", "https://example.com/a?q=one&b=two#fragment");
        equal("A page title\nhttps://example.com/page", "https://example.com/page");
        equal("  https://example.com  ", "https://example.com");
        equal("https://one.example https://two.example", null);
        equal("file:///tmp/link", null);
        equal("javascript:alert(1)", null);
        equal("https://user:pass@example.com", null);
        equal("https:///missing-host", null);
        equal("A plain title", null);
        equal(null, null);
        equal("https://example.com/" + "x".repeat(2048), null);
        System.out.println("PASS: shared link extraction, titles, ambiguity, unsafe schemes and length limits");
    }
}
