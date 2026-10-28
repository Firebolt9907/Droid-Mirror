package app.droidmirror.wear;

import android.content.Context;
import android.os.Handler;
import android.os.Looper;
import android.os.SystemClock;
import app.droidmirror.wearprotocol.WearProtocol;
import com.google.android.gms.wearable.CapabilityClient;
import com.google.android.gms.wearable.Wearable;
import org.json.JSONObject;
import java.util.HashSet;
import java.util.Set;
import java.util.UUID;

/** Only live MessageClient state is retained, in memory, with a monotonic deadline. */
final class WatchState {
    static final Handler MAIN = new Handler(Looper.getMainLooper());
    static JSONObject state;
    static String node = "", message = "Connecting to phone…", pending = "";
    static long received;
    static final Set<Runnable> observers = new HashSet<>();
    static boolean fresh() { return state != null && SystemClock.elapsedRealtime() - received < WearProtocol.LEASE_MS; }
    static String session() { return fresh() ? state.optString("session") : ""; }
    static void changed() { for (Runnable observer : new HashSet<>(observers)) observer.run(); }
    static void request(Context ctx) {
        Wearable.getCapabilityClient(ctx).getCapability(WearProtocol.PHONE_CAPABILITY, CapabilityClient.FILTER_REACHABLE)
            .addOnSuccessListener(capability -> {
                // Fail closed if more than one phone claims the role.
                if (capability.getNodes().size() != 1) { offline(ctx); return; }
                String phone = capability.getNodes().iterator().next().getId();
                Wearable.getMessageClient(ctx).sendMessage(phone, WearProtocol.REQUEST, new byte[0])
                    .addOnFailureListener(error -> offline(ctx));
            }).addOnFailureListener(error -> offline(ctx));
    }
    static void receive(Context ctx, String source, String path, byte[] bytes) {
        if (bytes.length > WearProtocol.MAX_BYTES) return;
        Wearable.getCapabilityClient(ctx).getCapability(WearProtocol.PHONE_CAPABILITY, CapabilityClient.FILTER_REACHABLE)
            .addOnSuccessListener(capability -> MAIN.post(() -> {
                if (capability.getNodes().size() != 1 || capability.getNodes().stream().noneMatch(n -> n.getId().equals(source))) return;
                try {
                    JSONObject value = new JSONObject(new String(bytes, java.nio.charset.StandardCharsets.UTF_8));
                    if (WearProtocol.STATE.equals(path)) {
                        if (value.optString("lease").isEmpty()) return;
                        boolean wasMirroring = !session().isEmpty();
                        state = value; node = source; received = SystemClock.elapsedRealtime();
                        if (wasMirroring && session().isEmpty()) message = "Mirroring ended";
                        else if (message.startsWith("Connecting") || message.startsWith("Phone unavailable")) message = "";
                        NowBarPublisher.update(ctx);
                        long generation = received;
                        MAIN.postDelayed(() -> { if (received == generation) offline(ctx); }, WearProtocol.LEASE_MS);
                        changed();
                    } else if (WearProtocol.RESULT.equals(path) && source.equals(node) && !pending.isEmpty()
                            && pending.equals(value.optString("request"))) {
                        pending = ""; message = value.optString("message"); changed(); request(ctx);
                    }
                } catch (org.json.JSONException ignored) { }
            }));
    }
    static void offline(Context ctx) {
        MAIN.post(() -> {
            state = null; node = ""; message = "Phone unavailable. Open DroidMirror on your phone.";
            NowBarPublisher.clear(ctx); changed();
        });
    }
    static void command(Context ctx, String action) {
        if (!fresh() || node.isEmpty()) { message = "Refreshing connection…"; changed(); request(ctx); return; }
        if (!pending.isEmpty()) return;
        JSONObject mac = state.optJSONObject("mac");
        String target = action.equals("stop") ? session() : mac == null ? "" : mac.optString("id");
        if (target.isEmpty()) return;
        String id = UUID.randomUUID().toString(); pending = id;
        message = action.equals("stop") ? "Requesting privacy stop…" : "Contacting Mac…"; changed();
        try {
            JSONObject value = new JSONObject().put("request", id).put("action", action)
                .put("lease", state.getString("lease")).put("target", target);
            Wearable.getMessageClient(ctx).sendMessage(node, WearProtocol.COMMAND,
                value.toString().getBytes(java.nio.charset.StandardCharsets.UTF_8))
                .addOnFailureListener(error -> complete(id, "Could not reach phone. Try again."));
        } catch (org.json.JSONException error) { complete(id, "Refresh the connection and try again."); }
        MAIN.postDelayed(() -> complete(id, "No confirmation. Check your phone or Mac."), 8000);
    }
    private static void complete(String id, String text) {
        MAIN.post(() -> { if (pending.equals(id)) { pending = ""; message = text; changed(); } });
    }
    private WatchState() {}
}
