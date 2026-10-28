package app.droidmirror.bluetooth;

import android.Manifest;
import android.app.Activity;
import android.bluetooth.*;
import android.bluetooth.le.*;
import android.content.Intent;
import android.content.pm.PackageManager;
import android.net.Uri;
import android.os.*;
import android.util.Base64;
import android.widget.*;
import com.google.zxing.integration.android.IntentIntegrator;
import com.google.zxing.integration.android.IntentResult;
import java.util.*;

/** Foreground-only, single-use delivery of the existing per-Mac key. */
public final class QRPairingActivity extends Activity {
    private final Handler main = new Handler(Looper.getMainLooper());
    private TextView status;
    private BluetoothLeScanner scanner;
    private BluetoothGatt gatt;
    private BluetoothGattCharacteristic target;
    private UUID service;
    private byte[] packet;
    private byte[] expectedAcknowledgement;
    private int sent;
    private boolean ended;
    private String peer;
    private final Runnable timeout = () -> fail("Pairing timed out. Open a fresh QR code on the Mac and try again.");

    @Override public void onCreate(Bundle state) {
        super.onCreate(state);
        LinearLayout root = new LinearLayout(this); root.setOrientation(LinearLayout.VERTICAL);
        root.setPadding(32, 48, 32, 32);
        status = new TextView(this); status.setTextSize(18); status.setText("Scan the QR code in DroidMirror on your Mac."); root.addView(status);
        Button close = new Button(this); close.setText("Close"); close.setOnClickListener(v -> finish()); root.addView(close);
        setContentView(root);
        peer = getIntent().getStringExtra("peer");
        if (peer == null || !BluetoothAdapter.checkBluetoothAddress(peer)) { fail("Select your paired Mac first."); return; }
        // The scanner owns its rotation state. Do not launch a second scanner after recreation.
        scanning = state != null && state.getBoolean("scanning", false);
        if (state == null) requestScanner();
        else if (!scanning) fail("Pairing interrupted. Close and scan a fresh QR code.");
    }
    private boolean scanning;
    @Override protected void onSaveInstanceState(Bundle state) { state.putBoolean("scanning", scanning); super.onSaveInstanceState(state); }
    private void requestScanner() {
        if (ended) return;
        String permission = Build.VERSION.SDK_INT >= 31 ? Manifest.permission.BLUETOOTH_SCAN : Manifest.permission.ACCESS_FINE_LOCATION;
        if (checkSelfPermission(permission) != PackageManager.PERMISSION_GRANTED) {
            requestPermissions(new String[]{permission}, 9); return;
        }
        scanning = true;
        new IntentIntegrator(this).setDesiredBarcodeFormats(IntentIntegrator.QR_CODE)
            .setPrompt("Scan the QR code shown by DroidMirror on your Mac")
            .setBeepEnabled(false).setBarcodeImageEnabled(false).initiateScan();
    }
    @Override public void onRequestPermissionsResult(int request, String[] permissions, int[] results) {
        super.onRequestPermissionsResult(request, permissions, results);
        if (request == 9 && results.length > 0 && results[0] == PackageManager.PERMISSION_GRANTED) requestScanner();
        else fail("Nearby device scanning permission is required for QR transfer. Manual copying is still available.");
    }
    @Override protected void onActivityResult(int request, int result, Intent data) {
        IntentResult scan = IntentIntegrator.parseActivityResult(request, result, data);
        if (scan == null) { super.onActivityResult(request, result, data); return; }
        scanning = false;
        if (scan.getContents() == null) { finish(); return; }
        byte[] secret = null, key = null;
        try {
            String contents = scan.getContents();
            if (contents.length() > 1024) throw new IllegalArgumentException();
            Uri uri = Uri.parse(contents);
            if (!"droidmirror-pair".equals(uri.getScheme()) || !"v1".equals(uri.getHost())) throw new IllegalArgumentException();
            String mac = uri.getQueryParameter("mac");
            if (!peer.equalsIgnoreCase(mac)) { fail("This QR code belongs to a different Mac. Select that Mac in setup first."); return; }
            String id = uri.getQueryParameter("service");
            service = UUID.fromString(id);
            if (!service.toString().equalsIgnoreCase(id)) throw new IllegalArgumentException();
            secret = Base64.decode(uri.getQueryParameter("secret"), Base64.URL_SAFE | Base64.NO_WRAP | Base64.NO_PADDING);
            BluetoothAdapter adapter = getSystemService(BluetoothManager.class).getAdapter();
            if (adapter == null || !adapter.isEnabled()) { fail("Enable Bluetooth and retry."); return; }
            boolean bonded = false;
            for (BluetoothDevice device : adapter.getBondedDevices()) if (peer.equalsIgnoreCase(device.getAddress())) bonded = true;
            if (!bonded) { fail("Pair this Mac in Android Bluetooth settings first."); return; }
            // Same accessor as Show pairing code: an existing key is returned unchanged.
            key = BlePairing.key(this, peer);
            packet = QRKeyTransfer.seal(key, secret, id, mac);
            expectedAcknowledgement = QRKeyTransfer.acknowledgement(packet, secret, id, mac);
            scanner = adapter.getBluetoothLeScanner();
            if (scanner == null) { fail("Bluetooth scanning is unavailable. Retry or use manual copying."); return; }
            status.setText("Finding the Mac’s temporary pairing service…");
            main.postDelayed(timeout, 90000);
            scanner.startScan(Collections.singletonList(new ScanFilter.Builder().setServiceUuid(new ParcelUuid(service)).build()),
                new ScanSettings.Builder().setScanMode(ScanSettings.SCAN_MODE_LOW_LATENCY).build(), scanCallback);
        } catch (Exception invalid) { fail("Could not start QR transfer. Use a fresh DroidMirror QR code and check Bluetooth permissions."); }
        finally {
            if (secret != null) Arrays.fill(secret, (byte)0);
            if (key != null) Arrays.fill(key, (byte)0);
        }
    }
    private final ScanCallback scanCallback = new ScanCallback() {
        @Override public void onScanResult(int type, ScanResult result) { main.post(() -> {
            if (ended || gatt != null) return;
            try {
                scanner.stopScan(this);
                status.setText("Sending the existing key securely…");
                gatt = result.getDevice().connectGatt(QRPairingActivity.this, false, callback, BluetoothDevice.TRANSPORT_LE);
                if (gatt == null) fail("Could not connect to the Mac. Retry with a fresh QR code.");
            } catch (RuntimeException failure) { fail("Bluetooth connection failed. Retry with a fresh QR code."); }
        }); }
        @Override public void onScanFailed(int error) { main.post(() -> fail("Bluetooth scanning failed. Close and retry.")); }
    };
    private final BluetoothGattCallback callback = new BluetoothGattCallback() {
        @Override public void onConnectionStateChange(BluetoothGatt source, int result, int state) { main.post(() -> {
            if (ended || source != gatt) return;
            if (result == BluetoothGatt.GATT_SUCCESS && state == BluetoothProfile.STATE_CONNECTED) {
                if (!source.discoverServices()) fail("Could not discover the pairing service.");
            } else fail("Mac disconnected before confirming the save. Check the Mac, then retry if needed.");
        }); }
        @Override public void onServicesDiscovered(BluetoothGatt source, int result) { main.post(() -> {
            if (ended || source != gatt) return;
            BluetoothGattService found = source.getService(service);
            target = found == null ? null : found.getCharacteristic(UUID.fromString(QRKeyTransfer.CHARACTERISTIC));
            if (result != BluetoothGatt.GATT_SUCCESS || target == null) { fail("Pairing invitation expired. Open a fresh QR code."); return; }
            writeNext();
        }); }
        @Override public void onCharacteristicWrite(BluetoothGatt source, BluetoothGattCharacteristic characteristic, int result) { main.post(() -> {
            if (ended || source != gatt) return;
            if (result != BluetoothGatt.GATT_SUCCESS) { fail("Mac did not accept the key. Check the Mac and scan a fresh QR code."); return; }
            if (sent == packet.length) {
                if (!source.readCharacteristic(target)) fail("Could not verify the Mac saved the key. Check the Mac before retrying.");
            } else writeNext();
        }); }
        @Override public void onCharacteristicRead(BluetoothGatt source, BluetoothGattCharacteristic characteristic, byte[] value, int result) {
            verifySaved(source, value, result);
        }
        @SuppressWarnings("deprecation") @Override public void onCharacteristicRead(BluetoothGatt source, BluetoothGattCharacteristic characteristic, int result) {
            if (Build.VERSION.SDK_INT < 33) verifySaved(source, characteristic.getValue(), result);
        }
    };
    private void verifySaved(BluetoothGatt source, byte[] value, int result) { main.post(() -> {
        if (ended || source != gatt) return;
        if (result != BluetoothGatt.GATT_SUCCESS || value == null || expectedAcknowledgement == null
            || !java.security.MessageDigest.isEqual(value, expectedAcknowledgement)) {
            fail("Could not authenticate the Mac’s save confirmation. Check the Mac before retrying."); return;
        }
        ended = true; cleanup();
        status.setText("Pairing key saved securely on the Mac. Your existing key is unchanged.");
    }); }
    @SuppressWarnings("deprecation") private void writeNext() {
        try {
            int end = Math.min(sent + 20, packet.length);
            target.setWriteType(BluetoothGattCharacteristic.WRITE_TYPE_DEFAULT);
            target.setValue(Arrays.copyOfRange(packet, sent, end));
            sent = end;
            if (!gatt.writeCharacteristic(target)) fail("Bluetooth could not send the key. Close and retry.");
        } catch (RuntimeException failure) { fail("Bluetooth transfer failed. Close and retry."); }
    }
    private void fail(String message) { ended = true; cleanup(); status.setText(message); }
    private void cleanup() {
        main.removeCallbacks(timeout);
        if (scanner != null) { try { scanner.stopScan(scanCallback); } catch (RuntimeException ignored) {} scanner = null; }
        if (gatt != null) { try { gatt.disconnect(); } catch (RuntimeException ignored) {} gatt.close(); gatt = null; }
        if (expectedAcknowledgement != null) { Arrays.fill(expectedAcknowledgement, (byte)0); expectedAcknowledgement = null; }
        if (packet != null) { Arrays.fill(packet, (byte)0); packet = null; }
    }
    @Override protected void onStop() {
        super.onStop();
        if (!scanning && !ended && packet != null) fail("Pairing interrupted. Keep this screen open and scan a fresh QR code.");
    }
    @Override protected void onDestroy() { ended = true; cleanup(); super.onDestroy(); }
}
