package app.droidmirror.bluetooth;

import android.Manifest;
import android.app.Activity;
import android.app.AlertDialog;
import android.app.NotificationManager;
import android.bluetooth.*;
import android.content.*;
import android.content.pm.PackageManager;
import android.graphics.Color;
import android.graphics.Typeface;
import android.graphics.drawable.GradientDrawable;
import android.os.*;
import android.provider.Settings;
import android.view.View;
import android.widget.*;
import java.util.ArrayList;
import java.util.List;
import rikka.shizuku.Shizuku;

/** Guided, resumable setup. The Mac starts every capture session. */
public final class CaptureActivity extends Activity {
    private final List<BluetoothDevice> peers = new ArrayList<>();
    private final Handler handler = new Handler(Looper.getMainLooper());
    private LinearLayout page;
    private Spinner picker;
    private TextView status, liveStatus, progress;
    private Button next;
    private CheckBox screenOff;
    private int step;
    private String chosenPeer = "";
    private boolean refreshing;
    private boolean grantingSecureSettings;
    private static final int ACCENT = Color.rgb(44, 91, 210);
    private final Runnable tick = new Runnable() {
        @Override public void run() { updateState(); handler.postDelayed(this, 1000); }
    };
    private final Shizuku.OnBinderReceivedListener binderReceived = () -> runOnUiThread(() -> {
        updateState(); CaptureService.enableIfConfigured(this); ensureSecureSettings();
    });
    private final Shizuku.OnBinderDeadListener binderDead = () -> runOnUiThread(this::updateState);
    private final Shizuku.OnRequestPermissionResultListener permissionResult = (request, result) -> runOnUiThread(() -> {
        updateState(); CaptureService.enableIfConfigured(this); ensureSecureSettings();
        status.setText(result == PackageManager.PERMISSION_GRANTED
            ? "Shizuku authorized. Continue to pair DroidMirror."
            : "Permission was denied. Tap Authorize Shizuku to try again.");
    });

    @Override public void onCreate(Bundle state) {
        super.onCreate(state);
        chosenPeer = getSharedPreferences("ready", MODE_PRIVATE).getString("setupPeer",
            getSharedPreferences("ready", MODE_PRIVATE).getString("peer", ""));
        step = state != null ? state.getInt("setupStep", 0)
            : getSharedPreferences("ready", MODE_PRIVATE).getInt("setupStep",
                getSharedPreferences("ready", MODE_PRIVATE).getBoolean("phoneSetupSeen", false) ? 3 : 0);
        step = Math.max(0, Math.min(3, step));
        if (state != null) chosenPeer = state.getString("chosenPeer", chosenPeer);
        if (getIntent().getBooleanExtra("pairMac", false)) step = 0;
        if (step > 0 && (!hasBluetoothPermissions() || !bluetoothEnabled() || chosenPeer.isEmpty() || !isBonded(chosenPeer))) step = 0;
        else if (step > 1 && !ShizukuDisplayClient.authorized()) step = 1;
        else if (step == 3 && (!BackgroundBridgePreferences.enabled(this)
            || !getSharedPreferences("ble_pairing", MODE_PRIVATE).contains(chosenPeer))) step = 2;
        render();
        Shizuku.addBinderReceivedListenerSticky(binderReceived);
        Shizuku.addBinderDeadListener(binderDead);
        Shizuku.addRequestPermissionResultListener(permissionResult);
    }

    private void render() {
        picker = null; screenOff = null;
        LinearLayout root = column(); root.setPadding(dp(24), dp(28), dp(24), dp(24));
        root.addView(text("DroidMirror", 16, true));
        root.addView(text("Your phone, on your Mac", 28, true));
        root.addView(text("Set up once. Start future sessions from your Mac.", 16, false));
        progress = text("STEP " + (step + 1) + " OF 4", 13, true); progress.setTextColor(ACCENT);
        root.addView(progress);
        LinearLayout dots = new LinearLayout(this);
        for (int i = 0; i < 4; i++) {
            View dot = new View(this);
            dot.setBackgroundColor(i <= step ? ACCENT : Color.rgb(220, 226, 238));
            LinearLayout.LayoutParams params = new LinearLayout.LayoutParams(0, dp(4), 1);
            params.setMargins(0, dp(8), dp(6), dp(16)); dots.addView(dot, params);
        }
        root.addView(dots);
        String[] titles = { "Connect Bluetooth", "Prepare your phone", "Pair DroidMirror", "Try your first mirror" };
        root.addView(text(titles[step], 24, true));
        page = column(); root.addView(page);
        liveStatus = text("", 15, true); root.addView(liveStatus);
        status = text("", 15, false); status.setAccessibilityLiveRegion(View.ACCESSIBILITY_LIVE_REGION_POLITE); root.addView(status);
        if (step == 0) bluetoothPage();
        else if (step == 1) shizukuPage();
        else if (step == 2) pairingPage();
        else finishPage();
        LinearLayout navigation = new LinearLayout(this);
        if (step > 0) navigation.addView(button("Back", () -> { step--; render(); }));
        next = button(step == 3 ? "Run setup again" : "Continue", () -> {
            if (step == 3) step = 0; else step++;
            render();
        });
        navigation.addView(next); root.addView(navigation);
        ScrollView scroll = new ScrollView(this); scroll.setFillViewport(true); scroll.addView(root); setContentView(scroll);
        if (picker != null) refreshPeers();
        updateState();
    }

    private void bluetoothPage() {
        card("1. Allow Nearby devices", "DroidMirror uses Bluetooth to find and securely connect to your Mac. Allow Nearby devices when prompted.");
        page.addView(button("Allow Nearby devices", this::requestBluetooth));
        card("2. Pair in Bluetooth settings", "Keep your Mac nearby. Open Bluetooth settings on both devices, select the other device and accept the matching system code. On the Mac: System Settings → Bluetooth.");
        page.addView(button("Open Bluetooth settings", () -> open(new Intent(Settings.ACTION_BLUETOOTH_SETTINGS))));
        page.addView(text("Choose your Mac", 16, true));
        picker = new Spinner(this); picker.setContentDescription("Paired Mac"); page.addView(picker);
        page.addView(button("Refresh paired devices", this::refreshPeers));
        page.addView(text("Only system-paired devices appear here. Choose your Mac, rather than headphones or another accessory. Pairing DroidMirror itself comes in step 3.", 14, false));
    }

    private void shizukuPage() {
        card("Why Shizuku?", "Shizuku gives DroidMirror permission to mirror and control your phone without a screen-share prompt every session. It may need to be started again after a phone restart.");
        card("1. Install and start Shizuku", "Open Shizuku and follow its setup guide. On Android 11 or newer, its wireless debugging method usually works without a cable. Return here once Shizuku says it is running.");
        page.addView(button("Get Shizuku / setup guide", () -> open(new Intent(Intent.ACTION_VIEW, android.net.Uri.parse("https://shizuku.rikka.app/guide/setup/")))));
        page.addView(button("Open Shizuku", () -> {
            Intent launch = getPackageManager().getLaunchIntentForPackage("moe.shizuku.privileged.api");
            if (launch == null) status.setText("Install Shizuku first using the setup guide above.");
            else open(launch);
        }));
        card("2. Allow DroidMirror", "Tap Authorize Shizuku below and allow access. If you denied access permanently, open Shizuku → Authorized applications and enable DroidMirror.");
        page.addView(button("Authorize Shizuku", () -> {
            try {
                if (!Shizuku.pingBinder() || Shizuku.getVersion() < 13)
                    status.setText("Start Shizuku 13 or newer, then return here and retry.");
                else if (ShizukuDisplayClient.authorized()) status.setText("Shizuku is already authorized. Continue below.");
                else Shizuku.requestPermission(7);
            } catch (RuntimeException error) { status.setText("Shizuku is unavailable. Open it, start it and retry."); }
            updateState();
        }));
    }

    private void pairingPage() {
        card("1. Save your private code on the Mac", "On your Mac, open DroidMirror → Set Up Phone… and choose this phone. At Pair DroidMirror, choose Pair with QR code and scan it here, or enter the code manually. This long private code is separate from the short system Bluetooth code.");
        page.addView(button("Scan Mac QR code", () -> {
            if (selectMac()) startActivity(new Intent(this, QRPairingActivity.class).putExtra("peer", chosenPeer));
        }));
        page.addView(button("Show pairing code", this::showCode));
        card("2. Keep the connection ready", "Enable the background bridge below. It lets your Mac start mirroring when needed. Your Mac will verify the private code on its first connection.");
        page.addView(button("Enable background bridge", this::enableBridge));
        page.addView(button("Connection recovery", this::showOptions));
        page.addView(text("You can leave this screen after setup. Bluetooth must stay on, and Shizuku must stay running. Wireless ADB and notification forwarding are optional.", 15, false));
    }

    private void finishPage() {
        card("1. Lock your phone", "Press your phone’s power button before starting. Optionally save your PIN under Optional features and recovery to unlock automatically before video starts. DroidMirror will wait while your phone is unlocked and in use.");
        card("2. Start on the Mac", "In the Mac setup, press Mirror my phone. A successful mirror verifies the pairing. Next time, just press Mirror on your Mac.");
        card("3. Keep these ready", "Keep Bluetooth on, Shizuku running and the background bridge enabled. On the same Wi-Fi, video can upgrade automatically. Wireless debugging is optional for video fallback.");
        page.addView(button("Enable / retry background bridge", this::enableBridge));
        page.addView(button("Optional features and recovery", this::showOptions));
        page.addView(text("If either app updates during a mirror session, let the old session end, reopen the apps and reconnect. Your saved pairing is retained.", 14, false));
        getSharedPreferences("ready", MODE_PRIVATE).edit().putBoolean("phoneSetupSeen", true).apply();
    }

    private void showCode() {
        if (!selectMac()) return;
        try {
            byte[] key = BlePairing.key(this, chosenPeer);
            String code;
            try { code = android.util.Base64.encodeToString(key, android.util.Base64.NO_WRAP); }
            finally { java.util.Arrays.fill(key, (byte) 0); }
            TextView value = text(code, 20, true); value.setTypeface(Typeface.MONOSPACE); value.setTextIsSelectable(true);
            value.setPadding(dp(24), dp(16), dp(24), dp(16));
            AlertDialog dialog = new AlertDialog.Builder(this).setTitle("Private DroidMirror code")
                .setMessage("For the selected Mac only. Enter all characters in the Mac’s Pair DroidMirror step, then Save pairing code. Keep this code private.")
                .setView(value).setPositiveButton("Done", null)
                .setNeutralButton("Copy code", null).create();
            dialog.setOnShowListener(ignored -> dialog.getButton(AlertDialog.BUTTON_NEUTRAL).setOnClickListener(v -> {
                android.content.ClipData clip = android.content.ClipData.newPlainText("DroidMirror private pairing code", code);
                if (Build.VERSION.SDK_INT >= 33) {
                    PersistableBundle extras = new PersistableBundle();
                    extras.putBoolean(android.content.ClipDescription.EXTRA_IS_SENSITIVE, true); clip.getDescription().setExtras(extras);
                }
                getSystemService(ClipboardManager.class).setPrimaryClip(clip);
                Toast.makeText(this, "Private code copied", Toast.LENGTH_SHORT).show();
            }));
            dialog.show();
        } catch (Exception error) { status.setText("Could not load pairing code. Retry: " + error.getMessage()); }
        updateState();
    }

    private void enableBridge() {
        if (!hasBluetoothPermissions()) { status.setText("Allow Nearby devices in step 1, then retry."); return; }
        if (!selectMac()) return;
        BackgroundBridgePreferences.setEnabled(this, true);
        CaptureService.ReadyResult result = CaptureService.enableIfConfigured(this);
        switch (result) {
            case START_REQUESTED: status.setText("Bridge start requested. Wait for the live status below, then continue on your Mac."); break;
            case PERMISSION_REQUIRED: status.setText("Nearby devices access is missing. Allow it in step 1 or Android Settings → Apps → DroidMirror → Permissions."); break;
            case BACKGROUND_RESTRICTED: status.setText("Android blocked background startup. Keep this app open and retry Enable background bridge."); break;
            default: status.setText("Bridge could not start. Check Bluetooth and retry. You can stop it under Optional features and recovery."); break;
        }
        updateState();
    }

    private boolean selectMac() {
        if (!hasBluetoothPermissions() || !bluetoothEnabled() || chosenPeer.isEmpty() || !isBonded(chosenPeer)) {
            status.setText("Return to Connect Bluetooth and select your paired Mac."); return false;
        }
        String previous = getSharedPreferences("ready", MODE_PRIVATE).getString("peer", "");
        if (chosenPeer.equals(previous)) return true;
        // Do not reset trust or swap service components under an active mirror.
        if (BackgroundBridgePreferences.enabled(this) || app.droidmirror.bluetooth.bridge.BridgeRuntime.Companion.getLive() != null) {
            status.setText("Before changing Macs, stop mirroring on your Mac, then stop the background bridge under Optional features and recovery.");
            return false;
        }
        getSharedPreferences("ready", MODE_PRIVATE).edit().putString("peer", chosenPeer).commit();
        return true;
    }

    private void showOptions() {
        LinearLayout options = column(); options.setPadding(dp(20), dp(8), dp(20), dp(8));
        options.addView(text("When the background bridge is enabled, DroidMirror restarts it automatically after a reboot and your first unlock. Keep Bluetooth permissions allowed. On non-rooted phones, start Shizuku again after each reboot; mirroring becomes ready once Shizuku is running and authorized. Stopping the background bridge also disables its automatic restart. Some phones require allowing auto-start in their battery settings.", 15, false));
        options.addView(button("Allow notification forwarding (optional)", () -> open(new Intent(Settings.ACTION_NOTIFICATION_LISTENER_SETTINGS))));
        if (Build.VERSION.SDK_INT >= 33 && checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) != PackageManager.PERMISSION_GRANTED)
            options.addView(button("Allow DroidMirror status notifications", () -> requestPermissions(new String[]{Manifest.permission.POST_NOTIFICATIONS}, 3)));
        options.addView(button("Notification forwarding setup and background features", () -> open(new Intent(this, app.droidmirror.bluetooth.bridge.BridgeSettingsActivity.class))));
        screenOff = new CheckBox(this); screenOff.setText("Turn phone display off while mirroring");
        screenOff.setChecked(getSharedPreferences("ready", MODE_PRIVATE).getBoolean("panelOff", true));
        screenOff.setOnCheckedChangeListener((v, checked) -> getSharedPreferences("ready", MODE_PRIVATE).edit().putBoolean("panelOff", checked).apply());
        options.addView(screenOff);
        CheckBox blackout = new CheckBox(this);
        blackout.setText("Black out phone with mirroring message (optional)");
        blackout.setChecked(getSharedPreferences("ready", MODE_PRIVATE).getBoolean("blackoutOverlay", false));
        blackout.setEnabled(ShizukuDisplayClient.authorized() && Build.VERSION.SDK_INT >= 31);
        screenOff.setEnabled(ShizukuDisplayClient.authorized() && !blackout.isChecked());
        blackout.setOnCheckedChangeListener((v, checked) -> {
            getSharedPreferences("ready", MODE_PRIVATE).edit().putBoolean("blackoutOverlay", checked).apply();
            screenOff.setEnabled(ShizukuDisplayClient.authorized() && !checked);
        });
        options.addView(blackout);
        options.addView(text("Applies to your next mirror session. The black overlay replaces panel-off mode and shows a grey mirroring message while your Mac shows the phone content. Press the power button to end mirroring and return to the lock screen. Requires Android 12 or later and Shizuku. The display remains powered on. Physical touchscreen input is blocked while Mac controls remain available.", 15, false));
        options.addView(button("Automatic unlock / saved PIN (optional)", () -> open(new Intent(this, UnlockPinActivity.class))));
        options.addView(button("Restore phone display", () -> ShizukuDisplayClient.restoreDisplay(this, value -> runOnUiThread(() -> status.setText(value)))));
        options.addView(button("Stop background bridge", () -> {
            BackgroundBridgePreferences.setEnabled(this, false);
            stopService(new Intent(this, CaptureService.class));
            status.setText("Background bridge stopped. Mirroring and notification forwarding are off."); updateState();
        }));
        ScrollView scroll = new ScrollView(this); scroll.addView(options);
        new AlertDialog.Builder(this).setTitle("Optional features and recovery").setView(scroll).setPositiveButton("Done", null).show();
    }

    private void updateState() {
        if (liveStatus == null || next == null) return;
        boolean bluetooth = hasBluetoothPermissions() && bluetoothEnabled();
        boolean selected = bluetooth && !chosenPeer.isEmpty() && isBonded(chosenPeer);
        boolean authorized = ShizukuDisplayClient.authorized();
        String saved = getSharedPreferences("ready", MODE_PRIVATE).getString("peer", "");
        boolean keySaved = !saved.isEmpty() && getSharedPreferences("ble_pairing", MODE_PRIVATE).contains(saved);
        app.droidmirror.bluetooth.bridge.BridgeRuntime runtime = app.droidmirror.bluetooth.bridge.BridgeRuntime.Companion.getLive();
        boolean bridge = BackgroundBridgePreferences.enabled(this) && runtime != null;
        String nearby = !hasBluetoothPermissions() ? "Nearby devices permission needed" : !bluetooth ? "Turn Bluetooth on" : !selected ? "Select a paired Mac" : "Bluetooth device selected";
        if (step == 0) liveStatus.setText(nearby);
        else if (step == 1) liveStatus.setText(authorized ? "✓ Shizuku authorized" : "Shizuku needs to be started and authorized");
        else liveStatus.setText((authorized ? "✓ Shizuku authorized" : "Start and authorize Shizuku") + "\n"
            + (!selected ? nearby : keySaved && saved.equals(chosenPeer) ? "✓ Private code available · verify on Mac" : "Show your private code first") + "\n"
            + (bridge ? "Bridge: " + runtime.getStatus() : BackgroundBridgePreferences.enabled(this) ? "Bridge enabled · waiting for service" : "Enable the background bridge"));
        next.setEnabled(step == 0 ? selected : step == 1 ? authorized
            : step == 2 ? bluetooth && selected && authorized && bridge && keySaved && saved.equals(chosenPeer) : true);
        if (screenOff != null) screenOff.setEnabled(authorized && !getSharedPreferences("ready", MODE_PRIVATE).getBoolean("blackoutOverlay", false));
    }

    private boolean hasBluetoothPermissions() {
        return Build.VERSION.SDK_INT < 31 || (checkSelfPermission(Manifest.permission.BLUETOOTH_CONNECT) == PackageManager.PERMISSION_GRANTED
            && checkSelfPermission(Manifest.permission.BLUETOOTH_ADVERTISE) == PackageManager.PERMISSION_GRANTED);
    }
    private boolean bluetoothEnabled() {
        if (!hasBluetoothPermissions()) return false;
        try { BluetoothAdapter adapter = getSystemService(BluetoothManager.class).getAdapter(); return adapter != null && adapter.isEnabled(); }
        catch (SecurityException denied) { return false; }
    }
    private boolean isBonded(String address) {
        if (!hasBluetoothPermissions()) return false;
        try {
            BluetoothAdapter adapter = getSystemService(BluetoothManager.class).getAdapter();
            if (adapter != null) for (BluetoothDevice peer : adapter.getBondedDevices()) if (address.equals(peer.getAddress())) return true;
        } catch (SecurityException ignored) { }
        return false;
    }
    private void requestBluetooth() {
        if (hasBluetoothPermissions()) { status.setText("Nearby devices allowed. Pair your Mac in Bluetooth settings below."); refreshPeers(); return; }
        requestPermissions(new String[]{Manifest.permission.BLUETOOTH_CONNECT, Manifest.permission.BLUETOOTH_ADVERTISE}, 2);
    }
    private void refreshPeers() {
        if (picker == null) return;
        refreshing = true;
        peers.clear(); List<String> labels = new ArrayList<>();
        if (hasBluetoothPermissions() && bluetoothEnabled()) {
            try {
                BluetoothAdapter adapter = getSystemService(BluetoothManager.class).getAdapter();
                peers.addAll(adapter.getBondedDevices());
                peers.sort((a, b) -> a.getAddress().compareTo(b.getAddress()));
                for (BluetoothDevice peer : peers) labels.add((peer.getName() == null ? "Bluetooth device" : peer.getName()) + " · " + peer.getAddress());
            } catch (SecurityException denied) { status.setText("Allow Nearby devices to load paired devices."); }
        }
        // Force an explicit choice; do not silently trust the first paired accessory.
        labels.add(0, "Select your Mac…");
        picker.setAdapter(new ArrayAdapter<>(this, android.R.layout.simple_spinner_dropdown_item, labels));
        int selected = 0;
        for (int i = 0; i < peers.size(); i++) if (chosenPeer.equals(peers.get(i).getAddress())) selected = i + 1;
        picker.setSelection(selected);
        picker.setOnItemSelectedListener(new AdapterView.OnItemSelectedListener() {
            @Override public void onItemSelected(AdapterView<?> parent, View view, int position, long id) {
                if (!refreshing) chosenPeer = position > 0 && position <= peers.size() ? peers.get(position - 1).getAddress() : "";
                updateState();
            }
            @Override public void onNothingSelected(AdapterView<?> parent) { }
        });
        refreshing = false; updateState();
    }
    private void open(Intent intent) {
        try { startActivity(intent); } catch (ActivityNotFoundException unavailable) { status.setText("That screen is unavailable. Open it manually in Settings."); }
    }
    private int dp(int value) { return Math.round(value * getResources().getDisplayMetrics().density); }
    private LinearLayout column() { LinearLayout result = new LinearLayout(this); result.setOrientation(LinearLayout.VERTICAL); return result; }
    private TextView text(String value, int size, boolean bold) {
        TextView view = new TextView(this); view.setText(value); view.setTextSize(size); view.setTextColor(Color.rgb(32, 42, 64));
        if (bold) view.setTypeface(Typeface.DEFAULT, Typeface.BOLD);
        view.setPadding(0, dp(6), 0, dp(8)); return view;
    }
    private Button button(String label, Runnable action) {
        Button result = new Button(this); result.setText(label); result.setAllCaps(false); result.setMinHeight(dp(48));
        result.setOnClickListener(v -> action.run()); return result;
    }
    private void card(String title, String detail) {
        LinearLayout card = column(); card.setPadding(dp(16), dp(10), dp(16), dp(12));
        GradientDrawable background = new GradientDrawable(); background.setColor(Color.rgb(240, 244, 252)); background.setCornerRadius(dp(16)); card.setBackground(background);
        card.addView(text(title, 17, true)); card.addView(text(detail, 15, false));
        LinearLayout.LayoutParams params = new LinearLayout.LayoutParams(-1, -2); params.setMargins(0, dp(8), 0, dp(10)); page.addView(card, params);
    }
    @Override protected void onResume() {
        super.onResume(); refreshPeers(); CaptureService.enableIfConfigured(this);
        handler.removeCallbacks(tick); handler.post(tick);
        ensureSecureSettings();
    }
    private void ensureSecureSettings() {
        if (grantingSecureSettings || !ShizukuDisplayClient.authorized() || SecureSettingsPermission.granted(this)) return;
        grantingSecureSettings = true;
        SecureSettingsPermission.ensure(this, value -> runOnUiThread(() -> {
            grantingSecureSettings = false;
            if (status != null) status.setText(value);
            app.droidmirror.bluetooth.bridge.BridgeRuntime runtime = app.droidmirror.bluetooth.bridge.BridgeRuntime.Companion.getLive();
            if (SecureSettingsPermission.granted(this) && runtime != null) runtime.findEndpoint();
        }));
    }
    @Override protected void onPause() {
        getSharedPreferences("ready", MODE_PRIVATE).edit().putInt("setupStep", step).putString("setupPeer", chosenPeer).apply();
        handler.removeCallbacks(tick); super.onPause();
    }
    @Override protected void onSaveInstanceState(Bundle state) {
        state.putInt("setupStep", step); state.putString("chosenPeer", chosenPeer); super.onSaveInstanceState(state);
    }
    @Override public void onRequestPermissionsResult(int request, String[] permissions, int[] grants) {
        super.onRequestPermissionsResult(request, permissions, grants); refreshPeers(); CaptureService.enableIfConfigured(this); updateState();
        if (request == 2 && !hasBluetoothPermissions()) status.setText("Nearby devices is required. Retry Allow Nearby devices, or open Android Settings → Apps → DroidMirror → Permissions if prompts are disabled.");
    }
    @Override protected void onDestroy() {
        handler.removeCallbacks(tick);
        Shizuku.removeBinderReceivedListener(binderReceived); Shizuku.removeBinderDeadListener(binderDead);
        Shizuku.removeRequestPermissionResultListener(permissionResult); super.onDestroy();
    }
}
