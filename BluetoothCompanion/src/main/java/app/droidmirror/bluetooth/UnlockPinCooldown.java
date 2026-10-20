package app.droidmirror.bluetooth;

/** A crash-surviving cooldown for intentional connection attempts, never a retry timer. */
final class UnlockPinCooldown {
    static final long DURATION_MS = 15000;
    static long remaining(long attemptedAt, long now) {
        // A legacy pause or a clock reset must not strand automatic entry.
        if (attemptedAt <= 0 || now < attemptedAt) return 0;
        long age = now - attemptedAt;
        return age >= DURATION_MS ? 0 : DURATION_MS - age;
    }
}
