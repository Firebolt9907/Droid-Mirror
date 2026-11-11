package app.droidmirror.bluetooth;

/** Consumes only the first decrypted, sequence-checked capture record. */
final class UnlockSessionAuthorization {
    private boolean consumed;
    private boolean allowed;
    // Dedicated startup record, never forwarded to scrcpy controls.
    static boolean isAuthorization(byte[] plain) {
        return plain.length == 6 && plain[0] == 0x71 && plain[1] == 0
            && plain[2] == 0 && plain[3] == 0 && plain[4] == 1
            && (plain[5] == 0 || plain[5] == 1);
    }
    synchronized void firstRecord(byte[] plain) {
        if (consumed) return;
        consumed = true;
        allowed = isAuthorization(plain) && plain[5] == 1;
    }
    synchronized boolean allowed() { return allowed; }
}
