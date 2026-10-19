import android.content.ClipData;
import android.content.ClipboardManager;
import android.content.Context;
import android.os.Looper;
import com.genymobile.scrcpy.FakeContext;
import com.genymobile.scrcpy.Workarounds;
import java.io.BufferedReader;
import java.io.InputStreamReader;

/** Interactive shell probe. Keeps the original clipboard only in memory; never prints contents. */
public final class ClipboardDeviceProbe {
    public static void main(String[] args) throws Exception {
        Looper.prepareMainLooper();
        Workarounds.apply();
        ClipboardManager clipboard = (ClipboardManager) FakeContext.get().getSystemService(Context.CLIPBOARD_SERVICE);
        ClipData original = clipboard.getPrimaryClip();
        ClipData testImage = null;
        BufferedReader input = new BufferedReader(new InputStreamReader(System.in));
        System.out.println("READY"); System.out.flush();
        try {
            String line;
            while ((line = input.readLine()) != null) {
                if (line.equals("restore")) break;
                String[] command = line.split(" ", 2);
                if (command.length != 2 || !command[1].startsWith("DroidMirror-test-")) throw new IllegalArgumentException("Test sentinel required");
                if (command[0].equals("set")) {
                    clipboard.setPrimaryClip(ClipData.newPlainText("DroidMirror test", command[1]));
                    System.out.println("SET");
                } else if (command[0].equals("check-image")) {
                    app.droidmirror.bluetooth.ClipboardBridgeService bridge = new app.droidmirror.bluetooth.ClipboardBridgeService();
                    String info = bridge.readFileInfo();
                    boolean match = false;
                    if (info != null) {
                        org.json.JSONObject file = new org.json.JSONObject(info);
                        java.security.MessageDigest digest = java.security.MessageDigest.getInstance("SHA-256");
                        int offset = 0;
                        while (offset < 5_000_000) {
                            byte[] chunk = bridge.readFileChunk(file.getString("uri"), offset);
                            if (chunk == null) break;
                            if (chunk.length == 0) {
                                StringBuilder hex = new StringBuilder();
                                for (byte b : digest.digest()) hex.append(String.format("%02x", b & 255));
                                match = command[1].equals("DroidMirror-test-" + hex);
                                break;
                            }
                            digest.update(chunk); offset += chunk.length;
                        }
                    }
                    if (match) testImage = clipboard.getPrimaryClip();
                    System.out.println(match ? "MATCH" : "NO_MATCH");
                } else if (command[0].equals("set-image")) {
                    if (testImage == null) throw new IllegalStateException("No received test image");
                    clipboard.setPrimaryClip(new ClipData(command[1], new String[]{"image/png"},
                        new ClipData.Item(testImage.getItemAt(0).getUri())));
                    System.out.println("SET");
                } else if (command[0].equals("check")) {
                    ClipData value = clipboard.getPrimaryClip();
                    System.out.println(value != null && value.getItemCount() == 1 && value.getItemAt(0).getText() != null && command[1].contentEquals(value.getItemAt(0).getText()) ? "MATCH" : "NO_MATCH");
                }
                System.out.flush();
            }
        } finally {
            try {
                ClipData current = clipboard.getPrimaryClip();
                CharSequence text = current == null || current.getItemCount() == 0 ? null : current.getItemAt(0).getText();
                CharSequence label = current == null ? null : current.getDescription().getLabel();
                boolean testUri = current != null && testImage != null && current.getItemCount() == 1
                    && testImage.getItemAt(0).getUri().equals(current.getItemAt(0).getUri());
                if ((text != null && text.toString().startsWith("DroidMirror-test-"))
                        || testUri || (label != null && label.toString().startsWith("DroidMirror-test-"))) {
                    if (original != null) {
                        try { clipboard.setPrimaryClip(original); } catch (Throwable ignored) { clipboard.clearPrimaryClip(); }
                    } else clipboard.clearPrimaryClip();
                }
            } catch (Throwable ignored) {}
            System.out.println("RESTORED"); System.out.flush();
        }
    }
}
