package android.app;
public class PendingIntent {
    public int sends;
    public boolean canceled;
    public void send() throws CanceledException { if (canceled) throw new CanceledException(); sends++; }
    public static class CanceledException extends Exception {}
}
