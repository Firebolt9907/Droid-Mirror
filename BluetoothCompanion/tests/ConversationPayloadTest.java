import app.droidmirror.bluetooth.bridge.ConversationPayload;
import org.json.JSONArray;
import org.json.JSONObject;
import java.nio.charset.StandardCharsets;
import java.util.ArrayList;
import java.util.List;

public final class ConversationPayloadTest {
    private static void check(boolean value) { if (!value) throw new AssertionError("Conversation payload regression"); }
    private static JSONObject message(String sender, String text, long timestamp) {
        return new JSONObject().put("sender", sender).put("text", text).put("timestamp", timestamp);
    }
    public static void main(String[] args) {
        var policy = ConversationPayload.INSTANCE;
        JSONArray pair = policy.messages(List.of(message("Tatha", "First message", 1), message("Tatha", "Second message", 2)));
        check(pair.length() == 2 && pair.getJSONObject(0).getString("text").equals("First message"));
        check(pair.getJSONObject(1).getString("text").equals("Second message"));
        JSONArray repeat = policy.messages(List.of(message("A", "Same text", 1), message("A", "Same text", 2)));
        check(repeat.length() == 2 && repeat.getJSONObject(1).getLong("timestamp") == 2);
        JSONArray outgoing = policy.messages(List.of(message("Me", "My reply", 3).put("outgoing", true)));
        check(outgoing.getJSONObject(0).getBoolean("outgoing"));
        check(!pair.getJSONObject(0).getBoolean("outgoing"));
        List<JSONObject> many = new ArrayList<>();
        for (int i = 0; i < 30; i++) many.add(message("Sender " + i, "😀".repeat(1000), i));
        JSONArray bounded = policy.messages(many);
        check(bounded.length() <= 12 && bounded.getJSONObject(bounded.length() - 1).getLong("timestamp") == 29);
        check(bounded.toString().getBytes(StandardCharsets.UTF_8).length <= 2800);
        check(!bounded.getJSONObject(0).getString("text").contains("\uFFFD"));
        JSONArray escaped = policy.messages(List.of(message("Sender", "\u0000".repeat(2000), 1)));
        check(escaped.toString().getBytes(StandardCharsets.UTF_8).length <= 2800);
        check(policy.messages(List.of()).length() == 0);
        System.out.println("Conversation history, repeated messages, chronology, UTF-8 and encrypted-budget tests passed");
    }
}
