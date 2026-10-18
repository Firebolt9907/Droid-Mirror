import app.droidmirror.bluetooth.bridge.MediaSyncProtocol;
import org.json.JSONArray;
import org.json.JSONObject;

public final class MediaSyncProtocolTest {
    private static void check(boolean condition) { if (!condition) throw new AssertionError(); }
    private static JSONObject snapshot() {
        return new JSONObject().put("active", true).put("id", "ABCDEF").put("title", "Song")
            .put("artist", "Artist").put("album", "Album").put("duration", 120.0).put("position", 20.0)
            .put("playing", true).put("actions", new JSONArray().put("play").put("pause").put("seek"));
    }
    public static void main(String[] args) {
        check(MediaSyncProtocol.validSnapshot(snapshot()));
        check(MediaSyncProtocol.fresh(1000, 8999));
        check(!MediaSyncProtocol.fresh(1000, 9000));
        check(!MediaSyncProtocol.fresh(1000, 999));
        for (String key : new String[]{"active", "id", "title", "artist", "album", "duration", "position", "playing", "actions"}) {
            JSONObject value = snapshot(); value.remove(key); check(!MediaSyncProtocol.validSnapshot(value));
        }
        check(!MediaSyncProtocol.validSnapshot(snapshot().put("active", false)));
        check(!MediaSyncProtocol.validSnapshot(snapshot().put("id", "")));
        check(!MediaSyncProtocol.validSnapshot(snapshot().put("id", "x".repeat(129))));
        check(!MediaSyncProtocol.validSnapshot(snapshot().put("title", "x".repeat(1025))));
        check(!MediaSyncProtocol.validSnapshot(snapshot().put("position", -1)));
        check(!MediaSyncProtocol.validSnapshot(snapshot().put("position", 604801)));
        check(!MediaSyncProtocol.validSnapshot(snapshot().put("playing", "true")));
        check(!MediaSyncProtocol.validSnapshot(snapshot().put("actions", new JSONArray().put("execute"))));
        System.out.println("PASS: Android media schema, bounds, actions and lease expiry");
    }
}
