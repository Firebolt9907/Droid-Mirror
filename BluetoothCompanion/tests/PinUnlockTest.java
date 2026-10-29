package app.droidmirror.bluetooth;
import com.genymobile.scrcpy.control.PinUnlock;

import java.util.ArrayList;
import java.util.List;
import java.nio.charset.StandardCharsets;

public final class PinUnlockTest {
    static final class Phone implements PinUnlock.Device {
        long time;
        boolean locked = true;
        int unlockAfterDigits;
        boolean enterUnlocks;
        int digits;
        long inputReadyAt;
        long bouncerReadyAt = Long.MAX_VALUE;
        long dismissAt = Long.MAX_VALUE;
        long dismissalDelay;
        long biometricAt = Long.MAX_VALUE;
        boolean simulateWake;
        boolean menuDisabled;
        final List<Integer> keys = new ArrayList<>();
        public long now() { return time; }
        public void sleep(long millis) { time += millis; }
        public boolean locked() {
            if (time >= dismissAt || time >= biometricAt) locked = false;
            return locked;
        }
        public void key(int key) {
            if (!locked) throw new AssertionError("Input leaked into unlocked app");
            keys.add(key);
            if (simulateWake) {
                if (time < inputReadyAt) return;
                if (key == 82 && menuDisabled) return;
                if (key == 62 || key == 82) { bouncerReadyAt = time + 500; return; }
                if (time < bouncerReadyAt) return;
            }
            if (key >= 7 && key <= 16 && ++digits == unlockAfterDigits) locked = false;
            if (key == 66 && enterUnlocks) {
                if (dismissalDelay == 0) locked = false;
                else dismissAt = time + dismissalDelay;
            }
        }
    }
    static void check(boolean result) { if (!result) throw new AssertionError(); }
    static byte[] pin(String text) { return text.getBytes(StandardCharsets.US_ASCII); }
    public static void main(String[] args) throws Exception {
        check(PinUnlock.valid(pin("0123")));
        for (String invalid : new String[]{"", "123", "12345678901234567", "123x", "12 3"})
            check(!PinUnlock.valid(pin(invalid)));
        Phone unlocked = new Phone(); unlocked.locked = false;
        PinUnlock.unlock(pin("0123"), unlocked); check(unlocked.keys.isEmpty());
        Phone normal = new Phone(); normal.enterUnlocks = true;
        PinUnlock.unlock(pin("0123"), normal);
        check(normal.keys.get(0) == 62 && normal.keys.get(normal.keys.size() - 1) == 66);
        check(normal.keys.subList(18, 22).equals(List.of(7, 8, 9, 10)));
        Phone auto = new Phone(); auto.unlockAfterDigits = 4;
        PinUnlock.unlock(pin("1234"), auto); check(!auto.keys.contains(66));
        Phone biometric = new Phone(); biometric.unlockAfterDigits = 1;
        PinUnlock.unlock(pin("1234"), biometric); check(biometric.digits == 1 && !biometric.keys.contains(66));
        Phone wrong = new Phone();
        try { PinUnlock.unlock(pin("1234"), wrong); throw new AssertionError("Wrong PIN accepted"); }
        catch (PinUnlock.Failure expected) {}
        check(wrong.digits == 4 && wrong.keys.stream().filter(k -> k == 66).count() == 1);
        check(wrong.time < 7000);
        Phone waking = new Phone(); waking.simulateWake = true; waking.inputReadyAt = 600;
        waking.unlockAfterDigits = 4;
        PinUnlock.unlock(pin("0123"), waking);
        check(waking.digits == 4 && !waking.keys.contains(66));
        // Awake lock screen: MENU is disabled, so waiting longer cannot fix it.
        Phone awake = new Phone(); awake.simulateWake = true; awake.menuDisabled = true;
        awake.unlockAfterDigits = 4;
        PinUnlock.unlock(pin("0123"), awake);
        check(awake.digits == 4 && !awake.keys.contains(82) && !awake.keys.contains(66));
        Phone slow = new Phone(); slow.enterUnlocks = true; slow.dismissalDelay = 3000;
        PinUnlock.unlock(pin("0123"), slow);
        check(slow.digits == 4 && slow.keys.stream().filter(k -> k == 66).count() == 1);
        Phone preparationBiometric = new Phone(); preparationBiometric.biometricAt = 500;
        PinUnlock.unlock(pin("0123"), preparationBiometric);
        check(preparationBiometric.keys.equals(List.of(62)));
        Phone invalid = new Phone();
        try { PinUnlock.unlock(pin("123x"), invalid); throw new AssertionError(); }
        catch (IllegalArgumentException expected) { check(invalid.keys.isEmpty()); }
        System.out.println("PinUnlockTest passed");
    }
}
