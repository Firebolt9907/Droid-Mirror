package com.genymobile.scrcpy.control;

/** One bounded attempt before capture. No PIN strings, logs, shell commands or retries. */
public final class PinUnlock {
    public interface Device {
        boolean locked() throws Exception;
        void key(int keycode) throws Exception;
        void sleep(long millis);
        long now();
    }
    public static final class Failure extends Exception {
        Failure() { super("Automatic unlock failed. Check the PIN on your phone and save it again in DroidMirror."); }
    }
    public static boolean valid(byte[] pin) {
        if (pin == null || pin.length < 4 || pin.length > 16) return false;
        for (byte digit : pin) if (digit < '0' || digit > '9') return false;
        return true;
    }
    public static void unlock(byte[] pin, Device device) throws Exception {
        if (!valid(pin)) throw new IllegalArgumentException("Invalid saved PIN");
        if (!device.locked()) return;
        device.key(82); // MENU opens the credential bouncer without leaving the last app.
        device.sleep(400);
        for (int i = 0; i < 16; i++) {
            if (!device.locked()) return;
            device.key(67); // DEL clears any partial lock-screen entry.
        }
        for (byte digit : pin) {
            // Stop if biometrics/Smart Lock/local input dismissed the keyguard.
            if (!device.locked()) return;
            device.key(7 + digit - '0'); // KEYCODE_0 … KEYCODE_9
            device.sleep(60);
        }
        device.sleep(250); // Some devices auto-confirm the final digit.
        if (device.locked()) device.key(66); // ENTER only while still on keyguard.
        long deadline = device.now() + 2000;
        while (device.locked()) {
            if (device.now() >= deadline) throw new Failure();
            device.sleep(25);
        }
        device.sleep(200); // Let the keyguard transition finish before encoding.
    }
}
