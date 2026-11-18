package android.bluetooth;
/** JVM stub: only the static address validator used by pure policy classes. */
public final class BluetoothAdapter {
    private BluetoothAdapter() {}
    public static boolean checkBluetoothAddress(String address) {
        return address != null && address.matches("[0-9A-F]{2}(:[0-9A-F]{2}){5}");
    }
}
