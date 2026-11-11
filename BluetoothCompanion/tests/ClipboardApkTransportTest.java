import app.droidmirror.bluetooth.bridge.ClipboardBulkCodec;
import app.droidmirror.bluetooth.bridge.ClipboardTransferRace;
import org.json.JSONObject;
import java.util.*;
import kotlin.Unit;

public final class ClipboardApkTransportTest {
    static void check(boolean value) { if (!value) throw new AssertionError(); }
    static void rejects(Runnable action) { try { action.run(); } catch (Throwable expected) { return; } throw new AssertionError("Accepted invalid declaration/chunk"); }
    public static void main(String[] args) {
        byte[] key = new byte[32]; String token = "12".repeat(32), id = UUID.randomUUID().toString().toUpperCase();
        ClipboardBulkCodec sender = new ClipboardBulkCodec(key, token, true), receiver = new ClipboardBulkCodec(key, token, false);
        JSONObject begin = new JSONObject().put("type", "clipboardFileBegin").put("id", id).put("destination", "install").put("name", "test.APK").put("size", 5_000_001).put("sha256", "a".repeat(64));
        receiver.open(sender.seal(begin));
        JSONObject chunk = new JSONObject().put("type", "clipboardFileChunk").put("id", id).put("offset", 5_000_000).put("data", "AQ==");
        check(receiver.open(sender.seal(chunk)).getInt("offset") == 5_000_000);
        rejects(() -> sender.seal(new JSONObject(chunk.toString()).put("offset", 5_000_001)));
        rejects(() -> sender.seal(new JSONObject(begin.toString()).put("destination", "downloads")));
        rejects(() -> sender.seal(new JSONObject(begin.toString()).put("size", 256 * 1024 * 1024)));
        rejects(() -> sender.seal(new JSONObject(begin.toString()).put("name", "test.zip")));
        ArrayList<Integer> lanes = new ArrayList<>(); ArrayList<JSONObject> delivered = new ArrayList<>();
        ClipboardTransferRace race = new ClipboardTransferRace((lane,event) -> { lanes.add(lane); return true; }, event -> { delivered.add(event); return Unit.INSTANCE; }, lane -> Unit.INSTANCE);
        race.receive(begin, 1); race.receive(begin, 0);
        check(delivered.size() == 1);
        check(race.send(new JSONObject().put("type", "clipboardFileAck").put("id", id).put("offset", 0)));
        race.receive(chunk, 0); check(delivered.size() == 1);
        race.receive(chunk, 1); check(delivered.size() == 2);
        check(race.send(new JSONObject().put("type", "clipboardFileAck").put("id", id).put("offset", 3072)));
        check(lanes.equals(List.of(1, 1))); // Window ACKs must continue on the selected lane.
        System.out.println("Android APK codec and single-lane tests passed");
    }
}
