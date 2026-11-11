import app.droidmirror.bluetooth.bridge.ClipboardSyncProgress;
import org.json.JSONObject;
import java.util.UUID;

public final class ClipboardSyncProgressTest {
    static void check(boolean value) { if (!value) throw new AssertionError(); }
    static JSONObject event(String type, String id) { return new JSONObject().put("type", type).put("id", id); }
    public static void main(String[] args) {
        ClipboardSyncProgress state = new ClipboardSyncProgress();
        String id = UUID.randomUUID().toString();
        JSONObject begin = event("clipboardFileBegin", id).put("size", 6);
        state.observe(begin, false); String token = state.getCurrent().getToken();
        check(state.matches(id, token));
        state.observe(begin, false); check(state.matches(id, token));
        JSONObject chunk = event("clipboardFileChunk", id).put("offset", 0).put("data", "YWJj");
        state.observe(chunk, false); state.observe(chunk, false); check(state.getCurrent().getBytes() == 3);
        state.observe(event("clipboardFileChunk", id).put("offset", 3).put("data", "ZGVm"), false);
        check(state.getCurrent().getBytes() == 6); // still active until apply ACK
        state.observe(event("clipboardFileAck", id).put("offset", 6), true);
        check(state.getCurrent() == null);
        state.observe(begin, false); check(state.getCurrent() == null); // late losing path
        String next = UUID.randomUUID().toString();
        state.observe(event("clipboardFileBegin", next).put("size", 10), true);
        check(!state.matches(id, token));
        check(!state.getCurrent().getToken().equals(token)); // fresh notification key per operation
        state.observe(event("clipboardFileAck", next).put("offset", 5), false);
        check(state.getCurrent().getBytes() == 5);
        state.clear();
        state.observe(event("clipboardFileBegin", next).put("size", 10), true);
        check(state.getCurrent() == null); // cancelled files cannot resurrect
        // Repeated incoming screenshots create a fresh activity every time, even
        // when delayed events from previous paths arrive during the next file.
        String previous = next;
        java.util.HashSet<String> tokens = new java.util.HashSet<>();
        for (int i = 0; i < 10; i++) {
            String fresh = UUID.randomUUID().toString();
            state.observe(event("clipboardFileBegin", fresh).put("size", 6), false);
            check(state.getCurrent() != null && tokens.add(state.getCurrent().getToken()));
            state.observe(event("clipboardFileBegin", previous).put("size", 6), false);
            state.observe(event("clipboardFileCancel", previous), false);
            check(state.getCurrent().getId().equals(fresh));
            state.observe(event("clipboardFileChunk", fresh).put("offset", 0).put("data", "YWJjZGVm"), false);
            state.observe(event("clipboardFileAck", fresh).put("offset", 6), true);
            check(state.getCurrent() == null);
            previous = fresh;
        }
        String preparingId = UUID.randomUUID().toString();
        state.observe(event("clipboardFilePrepare", preparingId), false);
        String preparingToken = state.getCurrent().getToken();
        check(state.getCurrent().getPreparing());
        state.observe(event("clipboardFileBegin", preparingId).put("size", 100), false);
        check(!state.getCurrent().getPreparing() && state.getCurrent().getSize() == 100 && state.matches(preparingId, preparingToken));
        state.clear();
        String aborted = UUID.randomUUID().toString();
        state.observe(event("clipboardFilePrepare", aborted), false);
        state.observe(event("clipboardFilePrepareEnd", aborted), false);
        state.observe(event("clipboardFileBegin", aborted).put("size", 100), false);
        check(state.getCurrent() == null);
        System.out.println("PASS: file-sync progress, race duplicate suppression, completion, cancellation and stale actions");
    }
}
