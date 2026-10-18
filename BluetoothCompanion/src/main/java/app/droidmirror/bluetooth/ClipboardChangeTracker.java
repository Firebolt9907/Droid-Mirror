package app.droidmirror.bluetooth;

/** Null means private/unavailable; empty means an accessible, empty clipboard. */
public final class ClipboardChangeTracker {
    private boolean baseline;
    private String previous;
    public boolean sample(String text) {
        if (text == null) { reset(); return false; }
        boolean changed = baseline && !text.equals(previous) && ClipboardTextPolicy.allowed(text);
        applied(text);
        return changed;
    }
    public void applied(String text) { previous = text; baseline = true; }
    public void reset() { previous = null; baseline = false; }
}
