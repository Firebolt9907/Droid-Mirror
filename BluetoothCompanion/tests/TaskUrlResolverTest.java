import app.droidmirror.bluetooth.TaskUrlResolver;

public final class TaskUrlResolverTest {
    private static final String DOCS = "com.google.android.apps.docs.editors.docs";
    private static final String EDITOR = "com.google.android.apps.docs.editors.kix.KixEditorActivity";
    private static final String VIEW = "android.intent.action.VIEW";
    private static void equal(String expected, String actual) {
        if (!java.util.Objects.equals(expected, actual)) throw new AssertionError("Unexpected resolution");
    }
    public static void main(String[] args) {
        equal("https://docs.google.com/document/d/abcdefghij_123/edit",
                TaskUrlResolver.resolve(DOCS, EDITOR, VIEW, "content://uniqueId/abcdefghij_123"));
        equal("https://example.com/document?a=1#section", TaskUrlResolver.resolve("app.other", "Editor", VIEW, "https://example.com/document?a=1#section"));
        equal(null, TaskUrlResolver.resolve("app.other", EDITOR, VIEW, "content://uniqueId/abcdefghij_123"));
        equal(null, TaskUrlResolver.resolve(DOCS, EDITOR, "android.intent.action.MAIN", "https://example.com"));
        for (String value : new String[]{"content://uniqueId/abcdefghij_123/other", "content://uniqueId/abcdefghij_123?x=1",
                "content://uniqueId/abc%2Fdefghijkl", "content://wrong/abcdefghij_123", "javascript:alert(1)",
                "file:///tmp/document", "https://user:password@example.com/", "https://example.com/\nsecret", "https:///missing-host"}) {
            equal(null, TaskUrlResolver.resolve(DOCS, EDITOR, VIEW, value));
        }
        System.out.println("PASS: Docs adapter, direct URLs, unknown metadata and unsafe URL rejection");
    }
}
