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

/** Authenticated bidirectional side channel. Classic is reserved for video. */
@SuppressLint("MissingPermission") // start checks both runtime permissions; callbacks handle revocation.
final class BleInputServer implements AutoCloseable {
    static final UUID SERVICE = UUID.fromString("c356a44e-6f2b-4da9-85e5-397991b8a610");
    static final UUID INPUT = UUID.fromString("c356a44e-6f2b-4da9-85e5-397991b8a611");
    static final UUID PROOF = UUID.fromString("c356a44e-6f2b-4da9-85e5-397991b8a612");
    static final UUID OUTPUT = UUID.fromString("c356a44e-6f2b-4da9-85e5-397991b8a613");
    static final UUID CLOCK = UUID.fromString("c356a44e-6f2b-4da9-85e5-397991b8a615");
    static final UUID RESUME = UUID.fromString("c356a44e-6f2b-4da9-85e5-397991b8a616");
    static final UUID REPLAY = UUID.fromString("c356a44e-6f2b-4da9-85e5-397991b8a617");
    static final UUID KEY = UUID.fromString("c356a44e-6f2b-4da9-85e5-397991b8a614");
    private static final UUID CCC = UUID.fromString("00002902-0000-1000-8000-00805f9b34fb");
    private final String selectedPeer;
    private final byte[] sessionNonce;
    private final BleInputCrypto returning;
    private volatile int mtu = 23;
    private final Object returnLock = new Object();
    private byte[] pendingReturn;
    private byte[] lastReadReturn = new byte[0];
    private CountDownLatch returnRead;
    private boolean returnIndicationInFlight;
    private BluetoothGattCharacteristic output;
    private volatile BluetoothDevice indicationPeer;
    private final ArrayBlockingQueue<ReturnRecord> replies = new ArrayBlockingQueue<>(32);
    private static final class ReturnRecord {
        final byte[] bytes;
        final CompletableFuture<Void> sent = new CompletableFuture<>();
        ReturnRecord(byte[] bytes) { this.bytes = bytes.clone(); }
    }
    private final Context context;
    private final BleInputCrypto crypto;
    private final java.util.UUID discovery;
    private final Runnable failed;
    private final ArrayBlockingQueue<byte[]> records = new ArrayBlockingQueue<>(64);
    private final CountDownLatch first = new CountDownLatch(1);
    private final AtomicBoolean closed = new AtomicBoolean();
    private BluetoothGattServer server;
    private BluetoothLeAdvertiser advertiser;
    private volatile BluetoothDevice authenticatedPeer;
    private final ConcurrentHashMap<String,byte[]> challenges=new ConcurrentHashMap<>();
    private byte[] clockValue;
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
    BleInputServer(Context context, byte[] key, String selectedPeer, Runnable failed) throws Exception {
        this.context = context; this.failed = failed;
        this.sessionNonce = key.clone(); this.selectedPeer = selectedPeer;
        byte[] pairing = BlePairing.key(context, selectedPeer);
        this.discovery = PairingKeys.discovery(PairingKeys.notifications(pairing));
        byte[] label = "DroidMirror BLE session v1".getBytes(java.nio.charset.StandardCharsets.US_ASCII);
        byte[] salt = java.nio.ByteBuffer.allocate(label.length + key.length).put(label).put(key).array();
        byte[] session = BleInputCrypto.hmac(pairing, salt); Arrays.fill(pairing, (byte)0);
        this.crypto = new BleInputCrypto(session); this.returning = new BleInputCrypto(session, true);
        Arrays.fill(session, (byte)0);
    }
    InputStream input() { return input; }
    private boolean selected(BluetoothDevice device) {
        return selectedPeer.equals(device.getAddress()) && device.getBondState() == BluetoothDevice.BOND_BONDED;
    }
    void send(byte[] bytes) throws IOException {
        if (closed.get() || bytes.length < 6 || bytes.length > BluetoothWire.MAX_CHUNK + 5) throw new IOException("BLE return channel unavailable");
        ReturnRecord record = new ReturnRecord(bytes);
        try {
            if (!replies.offer(record, 1, TimeUnit.SECONDS)) throw new IOException("BLE return queue full");
            record.sent.get(8, TimeUnit.SECONDS);
        } catch (InterruptedException error) { Thread.currentThread().interrupt(); throw new IOException(error); }
        catch (ExecutionException | TimeoutException error) { fail(); throw new IOException("BLE return transmission stalled", error); }
    }
    private void sendReplies() {
        ReturnRecord record = null;
        try {
            while (!closed.get()) {
                record = replies.poll(1, TimeUnit.SECONDS);
                if (record == null) continue;
                boolean report = record.bytes[0] != 1 || record.bytes[5] != BluetoothWire.ALIVE;
                if (report) android.util.Log.i("DroidMirrorBleInput", "Sending return record type=" + record.bytes[0] + " bytes=" + record.bytes.length);
                if (authenticatedPeer == null) throw new IOException("BLE return peer unauthenticated");
                int payload = Math.min(512, mtu - 3) - 24;
                if (payload <= 0) throw new IOException("BLE return MTU too small");
                for (int offset = 0; offset < record.bytes.length; offset += payload) {
                    byte[] packet = returning.seal(Arrays.copyOfRange(record.bytes, offset, Math.min(record.bytes.length, offset + payload)));
                    CountDownLatch sent = new CountDownLatch(1);
                    synchronized (returnLock) { pendingReturn = packet; returnRead = sent; }
                    // An ATT read can remain outstanding on macOS and prevent
                    // input/lease writes from reaching Android. Indications use
                    // the server-to-client transaction lane instead. Keep reads
                    // available for older Macs that never subscribe.
                    indicateReturn();
                    // Allow the Mac's bounded service rediscovery and same-session proof.
                    if (!sent.await(6, TimeUnit.SECONDS) || closed.get()) throw new IOException("BLE return delivery stalled");

                }
                record.sent.complete(null); record = null;
                if (report) android.util.Log.i("DroidMirrorBleInput", "Return record delivered");
            }
        } catch (Exception error) {
            if (record != null) record.sent.completeExceptionally(error);
            if (!closed.get()) fail();
        }
    }
    private void indicateReturn() throws IOException {
        synchronized (returnLock) {
            if (pendingReturn == null || returnIndicationInFlight || authenticatedPeer == null
                    || !authenticatedPeer.equals(indicationPeer)) return;
            returnIndicationInFlight = true;
            boolean queued;
            if (Build.VERSION.SDK_INT >= 33) {
                queued = server.notifyCharacteristicChanged(authenticatedPeer, output, true, pendingReturn)
                    == BluetoothStatusCodes.SUCCESS;
            } else {
                output.setValue(pendingReturn);
                queued = server.notifyCharacteristicChanged(authenticatedPeer, output, true);
            }
            if (!queued) { returnIndicationInFlight = false; throw new IOException("BLE return indication unavailable"); }
        }
    }
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
                AdvertiseData data = new AdvertiseData.Builder().addServiceUuid(new ParcelUuid(discovery)).build();
                advertiser.startAdvertising(settings, data, advertising);
            } catch (RuntimeException error) { fail(); }
        }
        @Override public void onConnectionStateChange(BluetoothDevice device, int status, int state) {
            if (state == BluetoothProfile.STATE_DISCONNECTED) {
                challenges.remove(device.getAddress());
                BleLinkMtu.disconnected(device.getAddress());
            } else if (state == BluetoothProfile.STATE_CONNECTED && selected(device)) {
                mtu = BleLinkMtu.get(device.getAddress());
            }
            if (device.equals(authenticatedPeer) && (state == BluetoothProfile.STATE_DISCONNECTED || status != BluetoothGatt.GATT_SUCCESS)) fail();
        }
        @Override public void onMtuChanged(BluetoothDevice device, int value) {
            BleLinkMtu.negotiated(device.getAddress(), value);
            if (selected(device)) mtu = value;
        }
        @Override public void onPhyUpdate(BluetoothDevice device, int tx, int rx, int status) {
            if (selected(device)) android.util.Log.i("DroidMirrorBleInput", "BLE PHY tx=" + tx + " rx=" + rx + " status=" + status);
        }
        @Override public void onDescriptorWriteRequest(BluetoothDevice device, int request, BluetoothGattDescriptor descriptor,
                boolean prepared, boolean response, int offset, byte[] value) {
            if (closed.get()) return;
            int result = BluetoothGatt.GATT_FAILURE;
            if (selected(device) && !prepared && offset == 0 && CCC.equals(descriptor.getUuid())
                    && descriptor.getCharacteristic() == output) {
                if (Arrays.equals(value, BluetoothGattDescriptor.ENABLE_INDICATION_VALUE)) {
                    indicationPeer = device; result = BluetoothGatt.GATT_SUCCESS;
                } else if (Arrays.equals(value, BluetoothGattDescriptor.DISABLE_NOTIFICATION_VALUE)) {
                    indicationPeer = null; result = BluetoothGatt.GATT_SUCCESS;
                }
            }
            if (response) server.sendResponse(device, request, result, 0, null);
            // Recovery can subscribe while the sender is waiting with the next
            // packet staged for legacy reads. Resume that exact ciphertext.
            if (result == BluetoothGatt.GATT_SUCCESS) {
                try { indicateReturn(); } catch (IOException error) { fail(); }
            }
        }
        @Override public void onDescriptorReadRequest(BluetoothDevice device, int request, int offset, BluetoothGattDescriptor descriptor) {
            if (closed.get()) return;
            boolean valid = selected(device) && offset == 0 && CCC.equals(descriptor.getUuid())
                && descriptor.getCharacteristic() == output;
            server.sendResponse(device, request, valid ? BluetoothGatt.GATT_SUCCESS : BluetoothGatt.GATT_FAILURE, 0,
                valid ? (device.equals(indicationPeer) ? BluetoothGattDescriptor.ENABLE_INDICATION_VALUE
                    : BluetoothGattDescriptor.DISABLE_NOTIFICATION_VALUE) : null);
        }
        @Override public void onNotificationSent(BluetoothDevice device, int status) {
            if (closed.get() || !device.equals(authenticatedPeer)) return;
            synchronized (returnLock) {
                if (status != BluetoothGatt.GATT_SUCCESS) {
                    android.util.Log.w("DroidMirrorBleInput", "Return indication failed: status=" + status);
                    fail(); return;
                }
                if (returnIndicationInFlight && returnRead != null && pendingReturn != null) {
                    returnIndicationInFlight = false;
                    lastReadReturn = pendingReturn;
                    pendingReturn = null; returnRead.countDown(); returnRead = null;
                }
            }
        }
        @Override public void onCharacteristicReadRequest(BluetoothDevice device, int request, int offset, BluetoothGattCharacteristic characteristic) {
            if (closed.get()) return;
            try {
                if (!selected(device)) {
                    server.sendResponse(device, request, BluetoothGatt.GATT_INSUFFICIENT_AUTHENTICATION, 0, null); return;
                }
                if (CLOCK.equals(characteristic.getUuid())) {
                    if (offset == 0) {
                        byte[] time = java.nio.ByteBuffer.allocate(8).putLong(SystemClock.uptimeMillis()).array();
                        clockValue = java.nio.ByteBuffer.allocate(40).put(time).put(crypto.clockProof(time)).array();
                    }
                    if (clockValue == null || offset < 0 || offset > 40) {
                        server.sendResponse(device, request, BluetoothGatt.GATT_INVALID_OFFSET, offset, null); return;
                    }
                    server.sendResponse(device, request, BluetoothGatt.GATT_SUCCESS, offset, Arrays.copyOfRange(clockValue,offset,40)); return;
                }
                if (OUTPUT.equals(characteristic.getUuid()) && offset == 0 && device.equals(authenticatedPeer)) {
                    synchronized (returnLock) {
                        if (device.equals(indicationPeer) || returnIndicationInFlight) {
                            server.sendResponse(device, request, BluetoothGatt.GATT_READ_NOT_PERMITTED, 0, null); return;
                        }
                        lastReadReturn=pendingReturn == null ? new byte[0] : pendingReturn;
                        server.sendResponse(device, request, BluetoothGatt.GATT_SUCCESS, 0, lastReadReturn);
                        if (pendingReturn != null) { pendingReturn = null; returnRead.countDown(); returnRead = null; }
                    }
                    return;
                }
                if (RESUME.equals(characteristic.getUuid()) && offset == 0 && device.equals(authenticatedPeer)) {
                    byte[] challenge=challenges.get(device.getAddress());
                    if (challenge==null) { server.sendResponse(device,request,BluetoothGatt.GATT_FAILURE,0,null); return; }
                    server.sendResponse(device,request,BluetoothGatt.GATT_SUCCESS,0,crypto.resumeState(challenge)); return;
                }
                if (REPLAY.equals(characteristic.getUuid()) && offset == 0 && device.equals(authenticatedPeer)) {
                    synchronized (returnLock) {
                        server.sendResponse(device,request,BluetoothGatt.GATT_SUCCESS,0,lastReadReturn);
                    }
                    return;
                }
                if (KEY.equals(characteristic.getUuid()) && offset >= 0 && offset <= 32) {
                    server.sendResponse(device, request, BluetoothGatt.GATT_SUCCESS, offset, Arrays.copyOfRange(sessionNonce, offset, 32)); return;
                }
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
                if (!selected(device)) {
                    if (response) server.sendResponse(device, request, BluetoothGatt.GATT_INSUFFICIENT_AUTHENTICATION, 0, null);
                    return;
                }
                if (!prepared && offset == 0 && PROOF.equals(characteristic.getUuid()) && value.length==16
                        && (challenges.size()<8 || challenges.containsKey(device.getAddress()))) {
                    // Stop new pushes while the Mac authenticates replacement
                    // attributes and reconciles the last delivered sequence.
                    indicationPeer = null;
                    challenges.put(device.getAddress(),value.clone());result=BluetoothGatt.GATT_SUCCESS;
                } else if (!prepared && offset == 0 && INPUT.equals(characteristic.getUuid())
                        && (authenticatedPeer == null || authenticatedPeer.equals(device))) {
                    byte[] plain = crypto.open(value);
                    if ((context.getApplicationInfo().flags & android.content.pm.ApplicationInfo.FLAG_DEBUGGABLE) != 0) android.util.Log.d("DroidMirrorBleInput", "Authenticated input sequence="
                        + java.nio.ByteBuffer.wrap(value).getLong() + " request=" + request + " response=" + response);
                    boolean newPeer = authenticatedPeer == null;
                    authenticatedPeer = device;
                    BleLinkMtu.observedWrite(device.getAddress(), value.length);
                    mtu = BleLinkMtu.get(device.getAddress());
                    if (newPeer) {
                        advertiser.stopAdvertising(advertising);
                        try {
                            server.setPreferredPhy(device, BluetoothDevice.PHY_LE_2M_MASK, BluetoothDevice.PHY_LE_2M_MASK,
                                BluetoothDevice.PHY_OPTION_NO_PREFERRED);
                        } catch (RuntimeException unsupported) {
                            android.util.Log.d("DroidMirrorBleInput", "Keeping negotiated BLE PHY");
                        }
                    }
                    if (!records.offer(plain)) { fail(); return; }
                    first.countDown(); result = BluetoothGatt.GATT_SUCCESS;
                }
            } catch (Exception invalid) {
                // An unauthenticated stranger must not terminate the owner's session.
                if (device.equals(authenticatedPeer)) { fail(); return; }
                try { server.cancelConnection(device); } catch (RuntimeException ignored) {}
            }
            if (response && !closed.get()) {
                try {
                    boolean sent = server.sendResponse(device, request, result, 0, null);
                    if ((context.getApplicationInfo().flags & android.content.pm.ApplicationInfo.FLAG_DEBUGGABLE) != 0) android.util.Log.d("DroidMirrorBleInput", "ATT response request=" + request + " queued=" + sent + " status=" + result);
                    if (!sent) fail();
                } catch (RuntimeException error) { fail(); }
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
            BluetoothGattCharacteristic.PROPERTY_WRITE, BluetoothGattCharacteristic.PERMISSION_WRITE));
        service.addCharacteristic(new BluetoothGattCharacteristic(PROOF,
            BluetoothGattCharacteristic.PROPERTY_READ | BluetoothGattCharacteristic.PROPERTY_WRITE,
            BluetoothGattCharacteristic.PERMISSION_READ | BluetoothGattCharacteristic.PERMISSION_WRITE));
        service.addCharacteristic(new BluetoothGattCharacteristic(KEY,
            BluetoothGattCharacteristic.PROPERTY_READ, BluetoothGattCharacteristic.PERMISSION_READ));
        service.addCharacteristic(new BluetoothGattCharacteristic(CLOCK,
            BluetoothGattCharacteristic.PROPERTY_READ, BluetoothGattCharacteristic.PERMISSION_READ));
        service.addCharacteristic(new BluetoothGattCharacteristic(RESUME,
            BluetoothGattCharacteristic.PROPERTY_READ, BluetoothGattCharacteristic.PERMISSION_READ));
        service.addCharacteristic(new BluetoothGattCharacteristic(REPLAY,
            BluetoothGattCharacteristic.PROPERTY_READ, BluetoothGattCharacteristic.PERMISSION_READ));
        output = new BluetoothGattCharacteristic(OUTPUT, BluetoothGattCharacteristic.PROPERTY_READ
            | BluetoothGattCharacteristic.PROPERTY_INDICATE, BluetoothGattCharacteristic.PERMISSION_READ);
        output.addDescriptor(new BluetoothGattDescriptor(CCC, BluetoothGattDescriptor.PERMISSION_READ | BluetoothGattDescriptor.PERMISSION_WRITE));
        service.addCharacteristic(output);
        new Thread(this::sendReplies, "BleControlReplies").start();
        if (!server.addService(service)) throw new IOException("BLE input service unavailable");
    }
    @Override public void close() {
        if (!closed.compareAndSet(false, true)) return;
        first.countDown(); records.clear(); challenges.clear(); Arrays.fill(sessionNonce, (byte)0);
        indicationPeer = null;
        synchronized (returnLock) { if (returnRead != null) returnRead.countDown(); pendingReturn = null; lastReadReturn = new byte[0]; }
        ReturnRecord pending;
        while ((pending = replies.poll()) != null) pending.sent.completeExceptionally(new IOException("BLE closed"));
        try { if (advertiser != null) advertiser.stopAdvertising(advertising); } catch (RuntimeException ignored) {}
        try { if (server != null) server.close(); } catch (RuntimeException ignored) {}
    }
}
