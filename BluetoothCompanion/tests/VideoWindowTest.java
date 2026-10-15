import app.droidmirror.bluetooth.VideoWindow;
import java.io.IOException;
import java.util.concurrent.*;

public final class VideoWindowTest {
    public static void main(String[] args) throws Exception {
        ExecutorService executor = Executors.newSingleThreadExecutor();
        try {
            VideoWindow window = new VideoWindow(4, 1000);
            window.reserve(4);
            Future<?> next = executor.submit(() -> { try { window.reserve(4); } catch(IOException e) { throw new RuntimeException(e); } });
            try { next.get(20, TimeUnit.MILLISECONDS); throw new AssertionError("Unacknowledged backlog exceeded capacity"); }
            catch(TimeoutException expected) {}
            window.acknowledge(4); next.get(1, TimeUnit.SECONDS);
            window.acknowledge(4); // Repeated cumulative acknowledgements are harmless.
            try { window.acknowledge(9); throw new AssertionError(); } catch(IOException expected) {}
            try { window.acknowledge(3); throw new AssertionError(); } catch(IOException expected) {}
            Future<?> stopped = executor.submit(() -> { try { window.reserve(1); throw new AssertionError(); } catch(IOException expected) {} });
            window.close(); stopped.get(1, TimeUnit.SECONDS);
            VideoWindow timeout = new VideoWindow(1, 20); timeout.reserve(1);
            try { timeout.reserve(1); throw new AssertionError(); } catch(IOException expected) {}
            System.out.println("VideoWindow: bounded backlog, cumulative ACK, validation, cancellation and stalled peer passed");
        } finally { executor.shutdownNow(); }
    }
}
