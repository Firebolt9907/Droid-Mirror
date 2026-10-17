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
    private TextView secureSettingsStatus;
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
        status.setText("Set up once: pair your Mac, authorize Shizuku, select the Mac and enable connections. Then press Mirror on your Mac whenever needed. There is no Android screen-share prompt.\n\n480p · up to 16 fps · HEVC 256 kbps target. Hybrid mode keeps HEVC when video upgrades to Wi-Fi; input stays on BLE. Direct ADB mode keeps ADB input and its selected codec. Protected content stays protected.");
        layout.addView(status);
        if (getIntent().getBooleanExtra("pairMac", false)) status.setText("Select your paired Mac below, then tap Pair Mac (mirroring and notifications). Paste that one code into DroidMirror → Pair Bluetooth… on your Mac.");
        secureSettingsStatus = new TextView(this); layout.addView(secureSettingsStatus);
        Button authorize = new Button(this); authorize.setText("Authorize Shizuku");
        authorize.setOnClickListener(v -> {
            try {
                if (!Shizuku.pingBinder() || Shizuku.getVersion() < 13) status.setText("Install and start Shizuku 13 or newer, then authorize it here. Shizuku setup may require wireless debugging or root; Bluetooth streaming does not use ADB.");
                else if (ShizukuDisplayClient.authorized()) { updateShizuku(); status.setText("Shizuku is already authorized."); }
                else Shizuku.requestPermission(7);
            } catch (RuntimeException error) { status.setText("Shizuku is unavailable. Start it and retry."); }
        }); layout.addView(authorize);
        Button notifications = new Button(this); notifications.setText("Allow notification forwarding");
        notifications.setOnClickListener(v -> startActivity(new Intent(android.provider.Settings.ACTION_NOTIFICATION_LISTENER_SETTINGS)));
        layout.addView(notifications);
        Button bridge = new Button(this); bridge.setText("Notifications and wireless ADB");
        bridge.setOnClickListener(v -> startActivity(new Intent(this, app.droidmirror.bluetooth.bridge.BridgeSettingsActivity.class)));
        layout.addView(bridge);
        picker = new Spinner(this); layout.addView(picker);
        Button refresh = new Button(this); refresh.setText("Refresh paired Macs"); refresh.setOnClickListener(v -> refresh()); layout.addView(refresh);
        Button pairing = new Button(this); pairing.setText("Pair Mac (mirroring and notifications)");
        pairing.setOnClickListener(v -> {
            if (peers.isEmpty()) { status.setText("Select a paired Mac first."); return; }
            try {
                String peer = peers.get(picker.getSelectedItemPosition()).getAddress();
                String code = android.util.Base64.encodeToString(BlePairing.key(this, peer), android.util.Base64.NO_WRAP);
                selectMac(peer);
                TextView text = new TextView(this); text.setText(code); text.setTextIsSelectable(true); text.setPadding(32, 24, 32, 24);
                new android.app.AlertDialog.Builder(this).setTitle("Pair mirroring and notifications").setView(text)
                    .setMessage("On the selected Mac, choose DroidMirror → Pair Bluetooth… and paste this code. This pairs mirroring, notifications and ADB discovery together. Enable the background bridge and allow notification forwarding in this Android app. Keep the code private.")
                    .setPositiveButton("Done", null)
                    .setNeutralButton("Allow notification forwarding", (dialog, which) ->
                        startActivity(new Intent(android.provider.Settings.ACTION_NOTIFICATION_LISTENER_SETTINGS))).show();
            } catch (Exception error) { status.setText("Could not load pairing code: " + error.getMessage()); }
        }); layout.addView(pairing);
        screenOff = new CheckBox(this); screenOff.setText("Turn phone panel off with Shizuku recovery");
        screenOff.setChecked(getSharedPreferences("ready", MODE_PRIVATE).getBoolean("panelOff", true)); layout.addView(screenOff);
        Button enable = new Button(this); enable.setText("Enable background bridge");
        enable.setOnClickListener(v -> {
            android.content.SharedPreferences.Editor setup = getSharedPreferences("ready", MODE_PRIVATE).edit()
                .putBoolean("panelOff", screenOff.isChecked());
            if (!peers.isEmpty()) selectMac(peers.get(picker.getSelectedItemPosition()).getAddress());
            setup.apply();
            BackgroundBridgePreferences.setEnabled(this, true);
            CaptureService.ReadyResult result = CaptureService.enableIfConfigured(this);
            if (result != CaptureService.ReadyResult.START_REQUESTED) status.setText("Could not start background bridge: " + result);
            else if (peers.isEmpty() || !ShizukuDisplayClient.authorized())
                status.setText("Background bridge enabled for notifications and ADB discovery. Select a paired Mac and authorize Shizuku to enable mirroring too.");
            else status.setText("Background bridge enabled. Start and stop mirroring on your Mac; notifications and ADB discovery stay available between sessions.");
        }); layout.addView(enable);
        Button restore = new Button(this); restore.setText("Restore phone display");
        restore.setOnClickListener(v -> ShizukuDisplayClient.restoreDisplay(this, text -> runOnUiThread(() -> status.setText(text)))); layout.addView(restore);
        Button disable = new Button(this); disable.setText("Stop background bridge");
        disable.setOnClickListener(v -> {
            BackgroundBridgePreferences.setEnabled(this, false);
            stopService(new Intent(this, CaptureService.class)); status.setText("Background bridge stopped. Mirroring readiness, discovery and notification forwarding are off.");
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
    @Override protected void onResume() {
        super.onResume();
        CaptureService.enableIfConfigured(this);
        updateShizuku();
    }
    private void selectMac(String peer) {
        String previous = getSharedPreferences("ready", MODE_PRIVATE).getString("peer", "");
        if (peer.equals(previous)) return;
        getSharedPreferences("ready", MODE_PRIVATE).edit().putString("peer", peer).commit();
        app.droidmirror.bluetooth.bridge.BridgeRuntime runtime = app.droidmirror.bluetooth.bridge.BridgeRuntime.Companion.getLive();
        if (runtime != null) runtime.resetTrust();
        CaptureService.enableIfConfigured(this);
    }
    private void updateShizuku() {
        screenOff.setEnabled(ShizukuDisplayClient.authorized());
        secureSettingsStatus.setText(SecureSettingsPermission.granted(this) ? "Secure settings authorized." :
            "Authorize Shizuku to grant secure settings for automatic Wireless debugging.");
        if (ShizukuDisplayClient.authorized() && !SecureSettingsPermission.granted(this)) {
            secureSettingsStatus.setText("Granting secure settings with Shizuku…");
            SecureSettingsPermission.ensure(this, text -> {
                secureSettingsStatus.setText(text);
                app.droidmirror.bluetooth.bridge.BridgeRuntime runtime = app.droidmirror.bluetooth.bridge.BridgeRuntime.Companion.getLive();
                if (SecureSettingsPermission.granted(this) && runtime != null) runtime.findEndpoint();
            });
        }
    }
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
