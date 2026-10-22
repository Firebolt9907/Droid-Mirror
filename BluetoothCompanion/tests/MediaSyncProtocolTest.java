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
        check(MediaSyncProtocol.validSnapshot(snapshot().put("actions", new JSONArray().put("shuffle").put("repeat"))));
        var remoteQueue = new app.droidmirror.bluetooth.bridge.RemoteMediaQueue();
        String revision = "a".repeat(64);
        JSONObject queueState = snapshot().put("queueRevision", revision)
            .put("actions", new JSONArray().put("play").put("queue"));
        check(MediaSyncProtocol.validSnapshot(queueState));
        remoteQueue.observe(queueState);
        JSONObject queue = new JSONObject().put("id", "ABCDEF").put("revision", revision).put("currentItemId", 123L)
            .put("items", new JSONArray().put(new JSONObject().put("queueItemId", 123L).put("title", "Current").put("artist", "Artist"))
                .put(new JSONObject().put("queueItemId", 9007199254740993L).put("title", "Next").put("artist", "Artist")));
        check(remoteQueue.receive(new JSONObject(queue.toString())));
        check(remoteQueue.command(9007199254740993L).getLong("queueItemId") == 9007199254740993L);
        check(remoteQueue.command(999) == null);
        check(!remoteQueue.receive(new JSONObject(queue.toString()).put("revision", "b".repeat(64))));
        check(!remoteQueue.receive(new JSONObject(queue.toString()).put("id", "other-track")));
        JSONObject invalidQueue = new JSONObject(queue.toString());
        invalidQueue.getJSONArray("items").getJSONObject(1).put("queueItemId", 123L);
        check(!remoteQueue.receive(invalidQueue));
        invalidQueue = new JSONObject(queue.toString());
        invalidQueue.getJSONArray("items").getJSONObject(1).put("queueItemId", 2.5);
        check(!remoteQueue.receive(invalidQueue));
        invalidQueue = new JSONObject(queue.toString()).put("currentItemId", 999);
        check(!remoteQueue.receive(invalidQueue));
        remoteQueue.observe(queueState); check(remoteQueue.getValue() != null);
        remoteQueue.observe(new JSONObject(queueState.toString()).put("queueRevision", "c".repeat(64)));
        check(remoteQueue.getValue() == null && remoteQueue.command(123) == null);
        remoteQueue.observe(queueState); check(remoteQueue.receive(queue));
        remoteQueue.observe(null); check(remoteQueue.getValue() == null && !remoteQueue.receive(queue));
        var sender = new app.droidmirror.bluetooth.bridge.MediaArtworkTransfer();
        var receiver = new app.droidmirror.bluetooth.bridge.MediaArtworkTransfer();
        String cover = "YWJj".repeat(3000);
        JSONObject announcement = sender.prepare(new JSONObject().put("artwork", cover));
        check(!announcement.has("artwork"));
        receiver.observe(announcement);
        JSONObject first = receiver.request(1000);
        check(first != null && receiver.request(1000) == null && receiver.request(2000) != null);
        JSONObject bad = sender.reply(first).put("offset", -1);
        check(!receiver.receive(bad));
        check(receiver.receive(sender.reply(first)));
        while (receiver.getCompleted() == null) {
            JSONObject reply = sender.reply(receiver.request(2000));
            check(reply.toString().length() < 5200);
            check(receiver.receive(reply));
        }
        check(cover.equals(receiver.getCompleted()));
        receiver.observe(new JSONObject());
        check(receiver.getCompleted() == null && !receiver.receive(sender.reply(first)));
        receiver.observe(announcement);
        bad = sender.reply(receiver.request(3000)).put("data", "X".repeat(4096));
        check(receiver.receive(bad));
        JSONObject request;
        while ((request = receiver.request(3000)) != null) check(receiver.receive(sender.reply(request)));
        check(receiver.getCompleted() == null);
        System.out.println("PASS: Android media schema, bounds, actions and lease expiry");
    }
}
