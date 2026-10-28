package app.droidmirror.bluetooth;

/** Durable snapshot, saved before suppression. Never overwrite a newer nonzero user setting. */
final class HapticVibrationLease {
    static final String ABSENT = "absent";
    interface Settings { String read() throws Exception; void write(String value) throws Exception; }
    interface Journal { String read(); void write(String value) throws Exception; }
    static boolean valid(String value) { return ABSENT.equals(value) || value != null && value.matches("-?[0-9]{1,10}"); }
    static String snapshot(Settings settings, Journal journal) throws Exception {
        restore(settings, journal);
        String value = settings.read();
        String saved = value == null ? ABSENT : value;
        if (!valid(saved)) throw new IllegalStateException("Vibration setting unavailable");
        journal.write(saved); // Durable before the shell may change the setting.
        return saved;
    }
    static void restore(Settings settings, Journal journal) throws Exception {
        if (journal.read() == null) return;
        restoreSetting(settings, journal);
        journal.write(null); // Keep the record on a failed restore, so startup can retry.
    }
    static void restoreSetting(Settings settings, Journal journal) throws Exception {
        String saved = journal.read();
        if (saved == null) return;
        if (!valid(saved)) throw new IllegalStateException("Invalid vibration recovery record");
        if ("0".equals(settings.read())) {
            String original = ABSENT.equals(saved) ? null : saved;
            settings.write(original);
            if (!java.util.Objects.equals(original, settings.read())) throw new IllegalStateException("Vibration restoration unconfirmed");
        }
    }
    private HapticVibrationLease() {}
}
