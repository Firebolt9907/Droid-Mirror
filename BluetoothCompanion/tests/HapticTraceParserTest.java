package app.droidmirror.bluetooth;
public final class HapticTraceParserTest {
    static void check(boolean value) { if (!value) throw new AssertionError(); }
    static String line(int thread, double time, String marker) {
        return " binder:1608_1-" + thread + "    ( 1608) [002] ..... " + String.format(java.util.Locale.ROOT, "%.6f", time) + ": tracing_mark_write: " + marker;
    }
    public static void main(String[] args) {
        HapticTraceParser parser = new HapticTraceParser(1608);
        check(!parser.accept(line(10, 10, "B|9000|vibrate"),10)); // app wrapper
        check(!parser.accept(line(10,10,"B|1608|unrelated"),10));
        check(parser.accept(line(10,10,"B|1608|vibrate"),10.001));
        check(!parser.accept(line(10,10,"B|1608|performHapticFeedback"),10.002)); // same request nested
        check(!parser.accept(line(10,10,"E|1608"),10.003));
        check(!parser.accept(line(10,10,"E|1608"),10.004));
        check(parser.accept(line(10,10,"B|1608|performHapticFeedbackForInputDevice"),10.005));
        check(parser.accept(line(11,10,"B|1608|vibrate"),10.006)); // independent thread
        check(!parser.accept(line(12,9,"B|1608|vibrate"),10)); // stale buffer
        check(!parser.accept(line(13,11,"B|1608|vibrate"),10)); // wrong clock
        check(!parser.accept("garbage",10));
        boolean lost = false;
        try { parser.accept("CPU:2 [LOST 50 EVENTS]",10); } catch (IllegalStateException expected) { lost=true; }
        check(lost);
        System.out.println("PASS: haptic service filtering, nesting, concurrent requests, stale records and trace loss");
    }
}
