import app.droidmirror.bluetooth.bridge.BleSecureSession;
import app.droidmirror.bluetooth.PairingKeys;
import app.droidmirror.bluetooth.bridge.BleFragments;
import org.json.JSONObject;
import java.io.BufferedReader;
import java.io.InputStreamReader;
import java.util.Arrays;

/** Runs the compiled Android Kotlin implementation against the Swift client. */
public final class BLESecurityPeer {
    public static void main(String[] args) throws Exception {
        byte[] key = new byte[32]; Arrays.fill(key, (byte) 7);
        BleSecureSession session = new BleSecureSession(PairingKeys.notifications(key));
        byte[] payload = new byte[8192]; Arrays.fill(payload, (byte) 42);
        BleFragments assembly = new BleFragments();
        byte[] result = null;
        for (byte[] frame : BleFragments.Companion.split(payload, 1, 20)) result = assembly.accept(frame);
        if (!Arrays.equals(result, payload)) throw new AssertionError("Fragment round trip");
        var invalid = BleFragments.Companion.split(new byte[100], 2, 20);
        BleFragments bad = new BleFragments();
        bad.accept(invalid.get(0));
        boolean rejected = false;
        try { bad.accept(invalid.get(2)); } catch (Exception expected) { rejected = true; }
        if (!rejected) throw new AssertionError("Out of order fragments accepted");
        BufferedReader input = new BufferedReader(new InputStreamReader(System.in));
        String line;
        while ((line = input.readLine()) != null) {
            try {
                JSONObject object = new JSONObject(line);
                JSONObject output;
                switch (object.optString("type")) {
                    case "hello": output = session.hello(object); break;
                    case "finish":
                        session.finish(object);
                        output = new JSONObject(new String(session.seal(new JSONObject().put("type", "ready")), java.nio.charset.StandardCharsets.UTF_8)); break;
                    default:
                        output = new JSONObject(new String(session.seal(session.open(object)), java.nio.charset.StandardCharsets.UTF_8)); break;
                }
                System.out.println(output);
            } catch (Exception expected) { System.out.println("{\"rejected\":true}"); }
            System.out.flush();
        }
    }
}
