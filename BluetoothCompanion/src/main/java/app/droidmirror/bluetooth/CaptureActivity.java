package app.droidmirror.bluetooth;

import android.Manifest;
import android.app.Activity;
import android.bluetooth.*;
import android.content.*;
import android.content.pm.PackageManager;
import android.os.*;
import android.widget.*;
import java.util.ArrayList;
import java.util.List;
import rikka.shizuku.Shizuku;

/** One-time pairing/permission setup. The Mac starts every capture session. */
public final class CaptureActivity extends Activity {
    private final List<BluetoothDevice> peers = new ArrayList<>();
    private Spinner picker;
    private TextView status;
    private CheckBox screenOff;
    private final Shizuku.OnBinderReceivedListener binderReceived = () -> runOnUiThread(() -> {
        updateShizuku(); CaptureService.enableIfConfigured(this);
    });
    private final Shizuku.OnBinderDeadListener binderDead = () -> runOnUiThread(this::updateShizuku);
    private final Shizuku.OnRequestPermissionResultListener permissionResult = (request, result) -> runOnUiThread(() -> {
        updateShizuku(); CaptureService.enableIfConfigured(this);
        status.setText(result == PackageManager.PERMISSION_GRANTED ? "Shizuku authorized. Enable your Mac below once; future sessions start from the Mac." : "Shizuku permission denied.");
    });
    @Override public void onCreate(Bundle state) {
        super.onCreate(state);
        LinearLayout layout = new LinearLayout(this); layout.setOrientation(LinearLayout.VERTICAL); layout.setPadding(32, 48, 32, 32);
        status = new TextView(this);
        status.setText("Set up once: pair your Mac, authorize Shizuku, select the Mac and enable connections. Then press Mirror on your Mac whenever needed. There is no Android screen-share prompt.\n\n480p · up to 16 fps · H.264 256 kbps target. Mouse, keyboard and navigation work over Bluetooth. Audio requires ADB mode. Protected content stays protected.");
        layout.addView(status);
        Button authorize = new Button(this); authorize.setText("Authorize Shizuku");
        authorize.setOnClickListener(v -> {
            try {
                if (!Shizuku.pingBinder() || Shizuku.getVersion() < 13) status.setText("Install and start Shizuku 13 or newer, then authorize it here. Shizuku setup may require wireless debugging or root; Bluetooth streaming does not use ADB.");
                else if (ShizukuDisplayClient.authorized()) { updateShizuku(); status.setText("Shizuku is already authorized."); }
                else Shizuku.requestPermission(7);
            } catch (RuntimeException error) { status.setText("Shizuku is unavailable. Start it and retry."); }
        }); layout.addView(authorize);
        picker = new Spinner(this); layout.addView(picker);
        Button refresh = new Button(this); refresh.setText("Refresh paired Macs"); refresh.setOnClickListener(v -> refresh()); layout.addView(refresh);
        Button pairing = new Button(this); pairing.setText("Show BLE pairing code");
        pairing.setOnClickListener(v -> {
            if (peers.isEmpty()) { status.setText("Select a paired Mac first."); return; }
            try {
                String peer = peers.get(picker.getSelectedItemPosition()).getAddress();
                String code = android.util.Base64.encodeToString(BlePairing.key(this, peer), android.util.Base64.NO_WRAP);
                TextView text = new TextView(this); text.setText(code); text.setTextIsSelectable(true); text.setPadding(32, 24, 32, 24);
                new android.app.AlertDialog.Builder(this).setTitle("Pair BLE with this Mac").setView(text)
                    .setMessage("Paste this code into DroidMirror Settings on the selected Mac. Keep it private; setup is needed only once.")
                    .setPositiveButton("Done", null).show();
            } catch (Exception error) { status.setText("Could not load pairing code: " + error.getMessage()); }
        }); layout.addView(pairing);
        screenOff = new CheckBox(this); screenOff.setText("Turn phone panel off with Shizuku recovery");
        screenOff.setChecked(getSharedPreferences("ready", MODE_PRIVATE).getBoolean("panelOff", true)); layout.addView(screenOff);
        Button enable = new Button(this); enable.setText("Enable Mac connections");
        enable.setOnClickListener(v -> {
            if (!ShizukuDisplayClient.authorized()) { status.setText("Authorize Shizuku first."); return; }
            if (peers.isEmpty()) { status.setText("Pair your Mac and refresh first."); return; }
            getSharedPreferences("ready", MODE_PRIVATE).edit().putString("peer", peers.get(picker.getSelectedItemPosition()).getAddress())
                .putBoolean("panelOff", screenOff.isChecked()).putBoolean("enabled", true).apply();
            CaptureService.enableIfConfigured(this);
            status.setText("Ready. Start and stop mirroring on your Mac. Keep Shizuku running; no phone action is needed for each session.");
        }); layout.addView(enable);
        Button restore = new Button(this); restore.setText("Restore phone display");
        restore.setOnClickListener(v -> ShizukuDisplayClient.restoreDisplay(this, text -> runOnUiThread(() -> status.setText(text)))); layout.addView(restore);
        Button disable = new Button(this); disable.setText("Disable Mac connections");
        disable.setOnClickListener(v -> {
            getSharedPreferences("ready", MODE_PRIVATE).edit().putBoolean("enabled", false).apply();
            stopService(new Intent(this, CaptureService.class)); status.setText("Mac connections disabled.");
        }); layout.addView(disable);
        ScrollView scroll = new ScrollView(this); scroll.addView(layout); setContentView(scroll);
        Shizuku.addBinderReceivedListenerSticky(binderReceived); Shizuku.addBinderDeadListener(binderDead);
        Shizuku.addRequestPermissionResultListener(permissionResult); updateShizuku();
        List<String> permissions = new ArrayList<>();
        if (Build.VERSION.SDK_INT >= 31 && checkSelfPermission(Manifest.permission.BLUETOOTH_CONNECT) != PackageManager.PERMISSION_GRANTED) permissions.add(Manifest.permission.BLUETOOTH_CONNECT);
        if (Build.VERSION.SDK_INT >= 31 && checkSelfPermission(Manifest.permission.BLUETOOTH_ADVERTISE) != PackageManager.PERMISSION_GRANTED) permissions.add(Manifest.permission.BLUETOOTH_ADVERTISE);
        if (Build.VERSION.SDK_INT >= 33 && checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) != PackageManager.PERMISSION_GRANTED) permissions.add(Manifest.permission.POST_NOTIFICATIONS);
        if (!permissions.isEmpty()) requestPermissions(permissions.toArray(new String[0]), 2); else { refresh(); CaptureService.enableIfConfigured(this); }
    }
    private void updateShizuku() { screenOff.setEnabled(ShizukuDisplayClient.authorized()); }
    private void refresh() {
        if (Build.VERSION.SDK_INT >= 31 && checkSelfPermission(Manifest.permission.BLUETOOTH_CONNECT) != PackageManager.PERMISSION_GRANTED) return;
        BluetoothAdapter adapter = getSystemService(BluetoothManager.class).getAdapter(); peers.clear(); List<String> labels = new ArrayList<>();
        if (adapter != null && adapter.isEnabled()) for (BluetoothDevice peer : adapter.getBondedDevices()) {
            peers.add(peer); labels.add(peer.getName() + " (" + peer.getAddress() + ")");
        }
        picker.setAdapter(new ArrayAdapter<>(this, android.R.layout.simple_spinner_dropdown_item, labels));
        String saved = getSharedPreferences("ready", MODE_PRIVATE).getString("peer", "");
        for (int i = 0; i < peers.size(); i++) if (saved.equals(peers.get(i).getAddress())) picker.setSelection(i);
    }
    @Override public void onRequestPermissionsResult(int request, String[] permissions, int[] grants) {
        super.onRequestPermissionsResult(request, permissions, grants); refresh(); CaptureService.enableIfConfigured(this);
    }
    @Override protected void onDestroy() {
        Shizuku.removeBinderReceivedListener(binderReceived); Shizuku.removeBinderDeadListener(binderDead);
        Shizuku.removeRequestPermissionResultListener(permissionResult); super.onDestroy();
    }
}
