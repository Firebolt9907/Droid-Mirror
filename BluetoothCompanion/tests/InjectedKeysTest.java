import com.genymobile.scrcpy.control.InjectedKeys;
import java.util.ArrayList;
import java.util.List;

public final class InjectedKeysTest {
    static final class Event {
        int action, key, repeat, meta, display, flags;
        long down, time;
        Event(int action, int key, int repeat, int meta, int display, long down, long time, int flags) {
            this.action = action; this.key = key; this.repeat = repeat; this.meta = meta;
            this.display = display; this.down = down; this.time = time; this.flags = flags;
        }
    }
    static void require(boolean value, String message) {
        if (!value) throw new AssertionError(message);
    }
    public static void main(String[] args) {
        List<Event> events = new ArrayList<>();
        InjectedKeys.Injector recorder = (a, k, r, m, d, down, now, f) -> {
            events.add(new Event(a, k, r, m, d, down, now, f)); return true;
        };
        InjectedKeys keys = new InjectedKeys();
        keys.inject(0, 29, 0, 0, 0, 100, recorder); // An ordinary letter also blocks Android's combination recognizer.
        keys.inject(0, 29, 1, 0, 0, 150, recorder);
        keys.inject(0, 26, 0, 0, 0, 160, recorder);
        keys.inject(0, 25, 0, 0, 2, 170, recorder);
        keys.releaseAll(200, recorder); // Abrupt control-channel disconnect, without any key-up messages.
        require(events.size() == 7, "Release every outstanding key once, including letters and power/volume");
        require(events.get(1).down == 100, "Repeats retain the original down time");
        for (int i = 4; i < 7; i++) {
            Event release = events.get(i);
            require(release.action == 1 && release.flags == 0x20 && release.meta == 0,
                    "Cleanup sends canceled key-up events without modifiers or shortcut activation");
        }
        require(events.get(6).display == 2, "Release on the same display as the press");
        keys.releaseAll(210, recorder);
        require(events.size() == 7, "Stop and receive-thread cleanup are idempotent");
        require(!keys.inject(0, 26, 0, 0, 0, 220, recorder), "No key-down may race in after stop");

        keys = new InjectedKeys();
        events.clear();
        keys.inject(0, 24, 0, 0, 0, 300, recorder);
        keys.inject(1, 24, 0, 0, 0, 310, recorder);
        keys.releaseAll(320, recorder);
        require(events.size() == 2 && events.get(1).down == 300, "A normally released key needs no cleanup");

        keys = new InjectedKeys();
        events.clear();
        keys.inject(0, 26, 0, 0, 0, 400, (a, k, r, m, d, down, now, f) -> false);
        keys.inject(0, 25, 0, 0, 0, 410, recorder);
        keys.inject(1, 25, 0, 0, 0, 420, (a, k, r, m, d, down, now, f) -> false);
        keys.releaseAll(430, (a, k, r, m, d, down, now, f) -> {
            if (k == 26) throw new IllegalStateException("Injection failed");
            return recorder.inject(a, k, r, m, d, down, now, f);
        });
        require(events.size() == 2 && events.get(1).key == 25, "A failed release cannot prevent other releases");
        keys.releaseAll(440, recorder);
        require(events.size() == 3 && events.get(2).key == 26, "Failed/uncertain presses are retried on final cleanup");
        System.out.println("PASS: disconnect cleanup, ordinary keys, power/volume, repeats, display routing, stop races and injection failures");
    }
}
