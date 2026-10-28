package app.droidmirror.bluetooth;
public final class HapticVibrationLeaseTest {
    static void check(boolean value) { if (!value) throw new AssertionError(); }
    static final class Settings implements HapticVibrationLease.Settings {
        String value; boolean fail;
        public String read() { return value; }
        public void write(String next) { if (fail) throw new IllegalStateException("provider unavailable"); value=next; }
    }
    static final class Journal implements HapticVibrationLease.Journal {
        String value; boolean fail;
        public String read() { return value; }
        public void write(String next) { if (fail) throw new IllegalStateException("disk full"); value=next; }
    }
    public static void main(String[] args) throws Exception {
        Settings settings = new Settings(); Journal journal = new Journal();
        check(HapticVibrationLease.snapshot(settings,journal).equals("absent"));
        settings.value="0";
        HapticVibrationLease.restore(settings,journal);
        check(settings.value==null && journal.value==null); // preserve absent value
        HapticVibrationLease.snapshot(settings,journal);
        settings.value="0";
        HapticVibrationLease.restoreSetting(settings,journal);
        check(settings.value==null && journal.value.equals("absent")); // early restore retains crash recovery
        settings.value="0"; // An already-running startup finishes after local takeover.
        HapticVibrationLease.restore(settings,journal);
        check(settings.value==null && journal.value==null); // final serialized close repairs it again
        settings.value="2";
        check(HapticVibrationLease.snapshot(settings,journal).equals("2"));
        settings.value="0"; settings.fail=true;
        try { HapticVibrationLease.restore(settings,journal); throw new AssertionError(); } catch (IllegalStateException expected) {}
        check(journal.value.equals("2")); // crash/reboot retry retains snapshot
        settings.fail=false;
        HapticVibrationLease.restore(settings,journal);
        check(settings.value.equals("2") && journal.value==null);
        settings.value="1"; HapticVibrationLease.snapshot(settings,journal); settings.value="3";
        HapticVibrationLease.restore(settings,journal);
        check(settings.value.equals("3")); // newer user preference wins
        settings.value="0"; HapticVibrationLease.snapshot(settings,journal);
        HapticVibrationLease.restore(settings,journal);
        check(settings.value.equals("0")); // originally disabled stays disabled
        journal.fail=true;
        try { HapticVibrationLease.snapshot(settings,journal); throw new AssertionError(); } catch (IllegalStateException expected) {}
        check(settings.value.equals("0")); // no change if durable snapshot cannot be saved
        check(!HapticVibrationLease.valid("1; echo unsafe"));
        System.out.println("PASS: exact vibration restoration, absent/disabled settings, newer edits and failed recovery retry");
    }
}
