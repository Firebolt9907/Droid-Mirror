import app.droidmirror.bluetooth.HandoffDiagnostics;
import java.util.Set;

public final class HandoffDiagnosticsTest {
    public static void main(String[] args) {
        String nativeListing = "Handoff-eligible tasks for user 0:\n  Task 14237: com.firebolt9907.tangentbrowser\n";
        if (!HandoffDiagnostics.packages(nativeListing).equals(Set.of("com.firebolt9907.tangentbrowser")))
            throw new AssertionError("device shell listing");
        String listing = "RemoteTask{packageName=com.google.android.youtube, title=private title}\n"
                + "RemoteTask{packageName=com.google.android.apps.maps, url=https://private.example/path}\n"
                + "RemoteTask{packageName=com.google.android.youtube}";
        if (!HandoffDiagnostics.packages(listing).equals(Set.of(
                "com.google.android.youtube", "com.google.android.apps.maps"))) throw new AssertionError();
        if (!HandoffDiagnostics.packages("Error: unknown command").isEmpty()) throw new AssertionError();
        if (!HandoffDiagnostics.packages("title=https://private.example/path").isEmpty()) throw new AssertionError();
        System.out.println("PASS: handoff package extraction, deduplication and exclusion of private content");
    }
}
