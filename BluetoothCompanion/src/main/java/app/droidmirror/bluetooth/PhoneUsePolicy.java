package app.droidmirror.bluetooth;

final class PhoneUsePolicy {
    static final String ERROR = "Phone is in use. Lock your phone, then try mirroring again.";
    static int startupFailure(Throwable error) {
        String message = error.getMessage();
        if (message != null && message.startsWith("Automatic unlock paused")) return BluetoothWire.PIN_PAUSED;
        if (message != null && message.startsWith("Automatic unlock failed")) return BluetoothWire.PIN_FAILED;
        return ERROR.equals(error.getMessage()) ? BluetoothWire.PHONE_IN_USE : BluetoothWire.CAPTURE_FAILED;
    }
}
