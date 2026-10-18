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
                } else if (command[0].equals("check")) {
                    ClipData value = clipboard.getPrimaryClip();
                    System.out.println(value != null && value.getItemCount() == 1 && value.getItemAt(0).getText() != null && command[1].contentEquals(value.getItemAt(0).getText()) ? "MATCH" : "NO_MATCH");
                }
                System.out.flush();
            }
        } finally {
            ClipData current = clipboard.getPrimaryClip();
            CharSequence text = current == null || current.getItemCount() == 0 ? null : current.getItemAt(0).getText();
            if (text != null && text.toString().startsWith("DroidMirror-test-")) {
                if (original != null) clipboard.setPrimaryClip(original); else clipboard.clearPrimaryClip();
            }
            System.out.println("RESTORED"); System.out.flush();
        }
    }
}
