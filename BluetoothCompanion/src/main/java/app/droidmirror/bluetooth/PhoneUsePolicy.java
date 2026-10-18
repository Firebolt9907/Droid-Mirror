package app.droidmirror.bluetooth;

final class PhoneUsePolicy {
    static final String ERROR = "Phone is in use. Lock your phone, then try mirroring again.";
    static int startupFailure(Throwable error) {
        return ERROR.equals(error.getMessage()) ? BluetoothWire.PHONE_IN_USE : BluetoothWire.CAPTURE_FAILED;
    }
}
