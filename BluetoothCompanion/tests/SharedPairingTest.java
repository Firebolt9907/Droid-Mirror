import app.droidmirror.bluetooth.BlePairing;
import app.droidmirror.bluetooth.PairingKeys;
import java.util.Arrays;
import java.util.Base64;

public final class SharedPairingTest {
    private static void check(boolean value, String message) { if (!value) throw new AssertionError(message); }
    public static void main(String[] args) throws Exception {
        var phone = new BackgroundBridgePreferencesTest.Phone();
        // Old standalone notification trust must never bypass shared Mac selection.
        phone.getSharedPreferences("ble_trust", 0).saved.put("key", "old standalone trust");
        check(BlePairing.notificationKey(phone) == null, "No default notification credential");
        phone.getSharedPreferences("ready", 0).saved.put("peer", "mac-a");
        check(BlePairing.notificationKey(phone) == null, "A BLE hello cannot create a pairing code");
        byte[] a = new byte[32]; for (int i = 0; i < a.length; i++) a[i] = (byte)i;
        byte[] b = new byte[32]; Arrays.fill(b, (byte)99);
        phone.getSharedPreferences("ble_pairing", 0).saved.put("mac-a", Base64.getEncoder().encodeToString(a));
        phone.getSharedPreferences("ble_pairing", 0).saved.put("mac-b", Base64.getEncoder().encodeToString(b));
        byte[] notification = BlePairing.notificationKey(phone);
        check(java.util.HexFormat.of().formatHex(notification).equals("612462f4f9c5c73d3d61fca80066dd8f099333d036948bdc116a3cb7d2fcf17b"), "Independent HMAC test vector");
        check(!Arrays.equals(a, notification), "Notification key is separated from input master");
        phone.getSharedPreferences("ready", 0).saved.put("peer", "mac-b");
        check(Arrays.equals(BlePairing.notificationKey(phone), PairingKeys.notifications(b)), "Selection uses that Mac's code");
        check(!Arrays.equals(notification, BlePairing.notificationKey(phone)), "Switching Macs changes notification trust");
        check(Arrays.equals(BlePairing.notificationKey(phone.reboot()), PairingKeys.notifications(b)), "Pairing survives restart");
        phone.getSharedPreferences("ble_pairing", 0).saved.put("mac-b", Base64.getEncoder().encodeToString(new byte[31]));
        try { BlePairing.notificationKey(phone); throw new AssertionError("Accepted invalid stored code"); }
        catch (java.security.GeneralSecurityException expected) {}
        System.out.println("PASS: shared pairing, key separation, Mac selection, restart, no legacy fallback, malformed code");
    }
}
