package app.droidmirror.bluetooth;

import android.Manifest;
import android.app.Activity;
import android.bluetooth.BluetoothAdapter;
import android.bluetooth.BluetoothDevice;
import android.bluetooth.BluetoothManager;
import android.content.Intent;
import android.content.pm.PackageManager;
import android.media.projection.MediaProjectionManager;
import android.os.Build;
import android.os.Bundle;
import android.widget.*;
import java.util.ArrayList;
import java.util.List;

public final class CaptureActivity extends Activity {
    private final List<BluetoothDevice> peers = new ArrayList<>();
    private Spinner picker;
    private TextView status;
    private String approvedPeer;

    @Override public void onCreate(Bundle state) {
        super.onCreate(state);
        LinearLayout layout = new LinearLayout(this);
        layout.setOrientation(LinearLayout.VERTICAL);
        layout.setPadding(32, 48, 32, 32);
        status = new TextView(this);
        status.setText("Pair your Mac in Bluetooth settings, select it below, then approve screen capture. Keep this screen open until the Mac connects.\n\n480p · up to 30 fps · H.264 1 Mbps\nVideo only. Audio and remote input require the ADB mode. Protected content stays hidden.");
        layout.addView(status);
        picker = new Spinner(this); layout.addView(picker);
        Button refresh = new Button(this); refresh.setText("Refresh paired Macs");
        refresh.setOnClickListener(v -> refresh()); layout.addView(refresh);
        Button start = new Button(this); start.setText("Start Bluetooth capture");
        start.setOnClickListener(v -> {
            if (peers.isEmpty()) { status.setText("Pair a Mac and refresh first."); return; }
            approvedPeer = peers.get(picker.getSelectedItemPosition()).getAddress();
            MediaProjectionManager manager = getSystemService(MediaProjectionManager.class);
            startActivityForResult(manager.createScreenCaptureIntent(), 1);
        }); layout.addView(start);
        Button stop = new Button(this); stop.setText("Stop capture");
        stop.setOnClickListener(v -> stopService(new Intent(this, CaptureService.class))); layout.addView(stop);
        setContentView(layout);
        if (Build.VERSION.SDK_INT >= 31 && checkSelfPermission(Manifest.permission.BLUETOOTH_CONNECT) != PackageManager.PERMISSION_GRANTED) {
            requestPermissions(new String[]{Manifest.permission.BLUETOOTH_CONNECT}, 2);
        } else refresh();
    }
    private void refresh() {
        if (Build.VERSION.SDK_INT >= 31 && checkSelfPermission(Manifest.permission.BLUETOOTH_CONNECT) != PackageManager.PERMISSION_GRANTED) return;
        BluetoothAdapter adapter = getSystemService(BluetoothManager.class).getAdapter();
        peers.clear();
        List<String> labels = new ArrayList<>();
        if (adapter != null && adapter.isEnabled()) {
            for (BluetoothDevice peer : adapter.getBondedDevices()) {
                peers.add(peer); labels.add(peer.getName() + " (" + peer.getAddress() + ")");
            }
        }
        picker.setAdapter(new ArrayAdapter<>(this, android.R.layout.simple_spinner_dropdown_item, labels));
        if (peers.isEmpty()) status.setText("Enable Bluetooth and pair your Mac in system settings, then refresh.");
    }
    @Override public void onRequestPermissionsResult(int request, String[] permissions, int[] grants) {
        super.onRequestPermissionsResult(request, permissions, grants);
        if (request == 2) refresh();
    }
    @Override protected void onActivityResult(int request, int result, Intent data) {
        super.onActivityResult(request, result, data);
        if (request != 1 || result != RESULT_OK || data == null || approvedPeer == null) return;
        Intent service = new Intent(this, CaptureService.class)
            .putExtra("permission", data).putExtra("result", result).putExtra("peer", approvedPeer);
        startForegroundService(service);
        status.setText("Capture approved. Select this phone in DroidMirror on your Mac and press Mirror. To restart after a disconnect, tap Start and approve capture again.");
    }
}
