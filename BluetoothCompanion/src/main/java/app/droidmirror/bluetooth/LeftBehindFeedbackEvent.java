package app.droidmirror.bluetooth;

/** Per-notification decision/lifetime policy, independent of radio and wall-clock changes. */
public final class LeftBehindFeedbackEvent {
    private LeftBehindFeedbackEvent() {}
    public static boolean choice(String value) { return "correct".equals(value) || "incorrect".equals(value); }
    public static long elapsed(long started, int startBoot, long now, int boot) {
        // After reboot the final disappearance time is unknown; never invent a duration.
        return startBoot >= 0 && startBoot == boot && started >= 0 && now >= started ? now - started : -1;
    }
    public static String duration(long ms) {
        if (ms < 0) return "duration unknown";
        long seconds = ms / 1000;
        return seconds >= 3600 ? (seconds / 3600) + "h " + (seconds % 3600 / 60) + "m " + (seconds % 60) + "s"
            : seconds >= 60 ? (seconds / 60) + "m " + (seconds % 60) + "s" : seconds + "s";
    }
}
