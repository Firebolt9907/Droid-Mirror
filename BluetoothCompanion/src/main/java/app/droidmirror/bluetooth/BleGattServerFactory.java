package app.droidmirror.bluetooth;

import android.bluetooth.BluetoothDevice;
import android.bluetooth.BluetoothGattServer;
import android.bluetooth.BluetoothGattServerCallback;
import android.bluetooth.BluetoothManager;
import android.content.Context;

/** Keep indications on LE when the same paired Mac also has a Classic GATT link. */
public final class BleGattServerFactory {
    private BleGattServerFactory() {}
    public static BluetoothGattServer open(Context context, BluetoothManager manager, BluetoothGattServerCallback callback) {
        try {
            return (BluetoothGattServer) BluetoothManager.class.getMethod("openGattServer", Context.class,
                BluetoothGattServerCallback.class, int.class).invoke(manager, context, callback, BluetoothDevice.TRANSPORT_LE);
        } catch (ReflectiveOperationException failure) {
            throw new IllegalStateException("Could not open an LE-only Bluetooth server", failure);
        }
    }
}
