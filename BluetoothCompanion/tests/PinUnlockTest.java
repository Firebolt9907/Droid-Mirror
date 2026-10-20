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
        final List<Integer> keys = new ArrayList<>();
        public long now() { return time; }
        public void sleep(long millis) { time += millis; }
        public boolean locked() { return locked; }
        public void key(int key) {
            if (!locked) throw new AssertionError("Input leaked into unlocked app");
            keys.add(key);
            if (key >= 7 && key <= 16 && ++digits == unlockAfterDigits) locked = false;
            if (key == 66 && enterUnlocks) locked = false;
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
        check(normal.keys.get(0) == 82 && normal.keys.get(normal.keys.size() - 1) == 66);
        check(normal.keys.subList(17, 21).equals(List.of(7, 8, 9, 10)));
        Phone auto = new Phone(); auto.unlockAfterDigits = 4;
        PinUnlock.unlock(pin("1234"), auto); check(!auto.keys.contains(66));
        Phone biometric = new Phone(); biometric.unlockAfterDigits = 1;
        PinUnlock.unlock(pin("1234"), biometric); check(biometric.digits == 1 && !biometric.keys.contains(66));
        Phone wrong = new Phone();
        try { PinUnlock.unlock(pin("1234"), wrong); throw new AssertionError("Wrong PIN accepted"); }
        catch (PinUnlock.Failure expected) {}
        check(wrong.digits == 4 && wrong.keys.stream().filter(k -> k == 66).count() == 1);
        check(wrong.time < 4000);
        Phone invalid = new Phone();
        try { PinUnlock.unlock(pin("123x"), invalid); throw new AssertionError(); }
        catch (IllegalArgumentException expected) { check(invalid.keys.isEmpty()); }
        System.out.println("PinUnlockTest passed");
    }
}
