package app.droidmirror.bluetooth;

import java.io.ByteArrayOutputStream;
import java.util.Arrays;

public final class PhoneUsePolicyTest {
    public static void main(String[] args) throws Exception {
        if (PhoneUsePolicy.startupFailure(new IllegalStateException(PhoneUsePolicy.ERROR)) != BluetoothWire.PHONE_IN_USE)
            throw new AssertionError("Local use must have a distinct error");
        if (PhoneUsePolicy.startupFailure(new IllegalStateException("Encoder unavailable")) != BluetoothWire.CAPTURE_FAILED)
            throw new AssertionError("Encoder errors must retain their meaning");
        if (PhoneUsePolicy.startupFailure(new IllegalStateException()) != BluetoothWire.CAPTURE_FAILED)
            throw new AssertionError("Empty errors must retain their meaning");
        if (PhoneUsePolicy.startupFailure(new IllegalStateException("Automatic unlock paused after an incomplete startup")) != BluetoothWire.PIN_PAUSED)
            throw new AssertionError("Paused PIN must not be reported as encoder failure");
        if (PhoneUsePolicy.startupFailure(new IllegalStateException("Automatic unlock failed. Check the PIN")) != BluetoothWire.PIN_FAILED)
            throw new AssertionError("Wrong PIN must have a distinct failure");
        ByteArrayOutputStream classic = new ByteArrayOutputStream(), ble = new ByteArrayOutputStream();
        BluetoothWire wire = new BluetoothWire(classic);
        wire.setSideChannel(ble::write);
        wire.event(BluetoothWire.PHONE_IN_USE);
        if (!Arrays.equals(ble.toByteArray(), new byte[]{1,0,0,0,1,8}))
            throw new AssertionError("Phone in use must reach the Mac over BLE before video starts");
        ble.reset(); wire.event(BluetoothWire.PIN_PAUSED); wire.event(BluetoothWire.PIN_FAILED);
        if (!Arrays.equals(ble.toByteArray(), new byte[]{1,0,0,0,1,9,1,0,0,0,1,10}))
            throw new AssertionError("PIN failures must reach the Mac before video");
        System.out.println("PASS: phone-in-use rejection reaches BLE with a distinct startup error");
    }
}
