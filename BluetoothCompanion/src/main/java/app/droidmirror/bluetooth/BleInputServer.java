package app.droidmirror.bluetooth;

import android.Manifest;
import android.annotation.SuppressLint;
import android.bluetooth.*;
import android.bluetooth.le.*;
import android.content.Context;
import android.content.pm.PackageManager;
import android.os.*;
import java.io.*;
import java.util.*;
import java.util.concurrent.*;
import java.util.concurrent.atomic.AtomicBoolean;

/** BLE only carries authenticated input/ACK records for the current Classic session. */
@SuppressLint("MissingPermission") // start checks both runtime permissions; callbacks handle revocation.
final class BleInputServer implements AutoCloseable {
    static final UUID SERVICE = UUID.fromString("c356a44e-6f2b-4da9-85e5-397991b8a610");
    static final UUID INPUT = UUID.fromString("c356a44e-6f2b-4da9-85e5-397991b8a611");
    static final UUID PROOF = UUID.fromString("c356a44e-6f2b-4da9-85e5-397991b8a612");
    private final Context context;
    private final BleInputCrypto crypto;
    private final Runnable failed;
    private final ArrayBlockingQueue<byte[]> records = new ArrayBlockingQueue<>(64);
    private final CountDownLatch first = new CountDownLatch(1);
    private final AtomicBoolean closed = new AtomicBoolean();
    private BluetoothGattServer server;
    private BluetoothLeAdvertiser advertiser;
    private BluetoothDevice authenticatedPeer;
    private final ConcurrentHashMap<String,byte[]> challenges=new ConcurrentHashMap<>();
    private byte[] current;
    private int offset;
    private final InputStream input = new InputStream() {
        @Override public int read() throws IOException {
            byte[] one = new byte[1]; return read(one, 0, 1) < 0 ? -1 : one[0] & 255;
        }
        @Override public int read(byte[] bytes, int start, int length) throws IOException {
            if (length == 0) return 0;
            while (!closed.get() && (current == null || offset == current.length)) {
                try { current = records.poll(1, TimeUnit.SECONDS); offset = 0; }
                catch (InterruptedException error) { Thread.currentThread().interrupt(); throw new IOException(error); }
            }
            if (closed.get()) return -1;
            int count = Math.min(length, current.length - offset);
            System.arraycopy(current, offset, bytes, start, count); offset += count; return count;
        }
        @Override public void close() { BleInputServer.this.close(); }
    };
    BleInputServer(Context context, byte[] key, Runnable failed) throws Exception {
        this.context = context; this.crypto = new BleInputCrypto(key); this.failed = failed;
    }
    InputStream input() { return input; }
    boolean awaitInput() throws InterruptedException { return first.await(15, TimeUnit.SECONDS) && !closed.get(); }
    private void fail() {
        if (closed.get()) return;
        close(); new Thread(failed, "BleInputFailure").start();
    }
    private final AdvertiseCallback advertising = new AdvertiseCallback() {
        @Override public void onStartFailure(int code) {
            android.util.Log.w("DroidMirrorBleInput", "BLE advertising failed: " + code); fail();
        }
    };
    private final BluetoothGattServerCallback callback = new BluetoothGattServerCallback() {
        @Override public void onServiceAdded(int status, BluetoothGattService service) {
            if (closed.get()) return;
            if (status != BluetoothGatt.GATT_SUCCESS) { fail(); return; }
            try {
                AdvertiseSettings settings = new AdvertiseSettings.Builder().setConnectable(true)
                    .setAdvertiseMode(AdvertiseSettings.ADVERTISE_MODE_LOW_LATENCY).build();
                AdvertiseData data = new AdvertiseData.Builder().addServiceUuid(new ParcelUuid(SERVICE)).build();
                advertiser.startAdvertising(settings, data, advertising);
            } catch (RuntimeException error) { fail(); }
        }
        @Override public void onConnectionStateChange(BluetoothDevice device, int status, int state) {
            if (state == BluetoothProfile.STATE_DISCONNECTED) challenges.remove(device.getAddress());
            if (device.equals(authenticatedPeer) && (state == BluetoothProfile.STATE_DISCONNECTED || status != BluetoothGatt.GATT_SUCCESS)) fail();
        }
        @Override public void onCharacteristicReadRequest(BluetoothDevice device, int request, int offset, BluetoothGattCharacteristic characteristic) {
            if (closed.get()) return;
            try {
                if (!PROOF.equals(characteristic.getUuid()) || offset < 0 || offset > 32) {
                    server.sendResponse(device, request, BluetoothGatt.GATT_INVALID_OFFSET, offset, null); return;
                }
                byte[] challenge=challenges.get(device.getAddress());
                if(challenge==null) { server.sendResponse(device,request,BluetoothGatt.GATT_FAILURE,0,null);return; }
                server.sendResponse(device, request, BluetoothGatt.GATT_SUCCESS, offset, Arrays.copyOfRange(crypto.proof(challenge), offset, 32));
            } catch (Exception error) { fail(); }
        }
        @Override public void onCharacteristicWriteRequest(BluetoothDevice device, int request, BluetoothGattCharacteristic characteristic,
                boolean prepared, boolean response, int offset, byte[] value) {
            if (closed.get()) return;
            int result = BluetoothGatt.GATT_FAILURE;
            try {
                if (!prepared && offset == 0 && PROOF.equals(characteristic.getUuid()) && value.length==16
                        && (challenges.size()<8 || challenges.containsKey(device.getAddress()))) {
                    challenges.put(device.getAddress(),value.clone());result=BluetoothGatt.GATT_SUCCESS;
                } else if (!prepared && offset == 0 && INPUT.equals(characteristic.getUuid())
                        && (authenticatedPeer == null || authenticatedPeer.equals(device))) {
                    byte[] plain = crypto.open(value);
                    authenticatedPeer = device;
                    if (!records.offer(plain)) { fail(); return; }
                    first.countDown(); result = BluetoothGatt.GATT_SUCCESS;
                }
            } catch (Exception invalid) {
                // An unauthenticated stranger must not terminate the owner's session.
                if (device.equals(authenticatedPeer)) { fail(); return; }
                try { server.cancelConnection(device); } catch (RuntimeException ignored) {}
            }
            if (response && !closed.get()) {
                try { server.sendResponse(device, request, result, 0, null); } catch (RuntimeException error) { fail(); }
            }
        }
    };
    void start() throws IOException {
        if (Build.VERSION.SDK_INT >= 31 && (context.checkSelfPermission(Manifest.permission.BLUETOOTH_ADVERTISE) != PackageManager.PERMISSION_GRANTED
                || context.checkSelfPermission(Manifest.permission.BLUETOOTH_CONNECT) != PackageManager.PERMISSION_GRANTED))
            throw new IOException("Grant Nearby Devices permission for BLE input");
        BluetoothManager manager = context.getSystemService(BluetoothManager.class);
        advertiser = manager.getAdapter().getBluetoothLeAdvertiser();
        if (advertiser == null) throw new IOException("BLE advertising unavailable");
        server = manager.openGattServer(context, callback);
        if (server == null) throw new IOException("BLE input GATT server unavailable");
        BluetoothGattService service = new BluetoothGattService(SERVICE, BluetoothGattService.SERVICE_TYPE_PRIMARY);
        service.addCharacteristic(new BluetoothGattCharacteristic(INPUT,
            BluetoothGattCharacteristic.PROPERTY_WRITE_NO_RESPONSE, BluetoothGattCharacteristic.PERMISSION_WRITE));
        service.addCharacteristic(new BluetoothGattCharacteristic(PROOF,
            BluetoothGattCharacteristic.PROPERTY_READ | BluetoothGattCharacteristic.PROPERTY_WRITE,
            BluetoothGattCharacteristic.PERMISSION_READ | BluetoothGattCharacteristic.PERMISSION_WRITE));
        if (!server.addService(service)) throw new IOException("BLE input service unavailable");
    }
    @Override public void close() {
        if (!closed.compareAndSet(false, true)) return;
        first.countDown(); records.clear(); challenges.clear();
        try { if (advertiser != null) advertiser.stopAdvertising(advertising); } catch (RuntimeException ignored) {}
        try { if (server != null) server.close(); } catch (RuntimeException ignored) {}
    }
}
