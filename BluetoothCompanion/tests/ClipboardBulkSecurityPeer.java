import app.droidmirror.bluetooth.bridge.ClipboardBulkCodec;
import app.droidmirror.bluetooth.bridge.BleBulkTestPayload;
import org.json.*;
import java.util.*;

public final class ClipboardBulkSecurityPeer {
    static void check(boolean value) { if (!value) throw new AssertionError(); }
    static void rejects(Runnable operation) { try { operation.run(); } catch (Throwable expected) { return; } throw new AssertionError("accepted invalid record"); }
    public static void main(String[] args) throws Exception {
        JSONObject request = new JSONObject(new String(System.in.readAllBytes(), java.nio.charset.StandardCharsets.UTF_8));
        byte[] key = Base64.getDecoder().decode(request.getString("key"));
        String token = request.getString("token");
        byte[] benchmarkKey = ClipboardBulkCodec.Companion.benchmarkKey(key);
        ClipboardBulkCodec phone = new ClipboardBulkCodec(key, token, false);
        JSONArray records = request.getJSONArray("records"), decoded = new JSONArray();
        for (int i = 0; i < records.length(); i++) {
            byte[] record = Base64.getDecoder().decode(records.getString(i));
            JSONObject value = phone.open(record); decoded.put(value);
            rejects(() -> phone.open(record));
        }
        byte[] first = Base64.getDecoder().decode(records.getString(0));
        byte[] altered = first.clone(); altered[altered.length - 1] ^= 1;
        rejects(() -> new ClipboardBulkCodec(key, token, false).open(altered));
        byte[] wrong = key.clone(); wrong[0] ^= 1;
        rejects(() -> new ClipboardBulkCodec(wrong, token, false).open(first));
        rejects(() -> new ClipboardBulkCodec(key, "a".repeat(64), false).open(first));
        rejects(() -> new ClipboardBulkCodec(key, token, false).open(new byte[100000]));
        rejects(() -> phone.seal(new JSONObject().put("type", "clipboardSet").put("text", "forbidden")));
        BleBulkTestPayload payload = new BleBulkTestPayload(4000);
        byte[] block = new byte[3072];
        for (int i = 0; i < block.length; i++) block[i] = (byte)(i % 251);
        check(!payload.append(0, block));
        rejects(() -> payload.append(0, block));
        rejects(() -> payload.sha256());
        byte[] tail = new byte[928];
        for (int i = 0; i < tail.length; i++) tail[i] = (byte)((3072 + i) % 251);
        byte[] badTail = tail.clone(); badTail[0] ^= 1;
        rejects(() -> payload.append(3072, badTail));
        check(payload.getCount() == 3072);
        check(payload.append(3072, tail));
        rejects(() -> payload.append(4000, new byte[]{0}));
        byte[] all = new byte[4000]; for (int i = 0; i < all.length; i++) all[i] = (byte)(i % 251);
        check(payload.sha256().equals(java.util.HexFormat.of().formatHex(java.security.MessageDigest.getInstance("SHA-256").digest(all))));
        rejects(() -> new BleBulkTestPayload(4_000_001));
        JSONArray replies = new JSONArray();
        for (int i = 0; i < request.getJSONArray("reply").length(); i++)
            replies.put(Base64.getEncoder().encodeToString(phone.seal(request.getJSONArray("reply").getJSONObject(i))));
        System.out.println(new JSONObject().put("benchmarkKey", Base64.getEncoder().encodeToString(benchmarkKey)).put("decoded", decoded).put("records", replies));
    }
}
