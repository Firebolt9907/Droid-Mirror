import app.droidmirror.bluetooth.VideoWindow;
import app.droidmirror.bluetooth.BluetoothWire;
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
            // Falling back with Wi-Fi bytes still in flight must stop new
            // Classic reservations until cumulative ACKs drain below its cap.
            int capacity = BluetoothWire.VIDEO_WINDOW_BYTES;
            VideoWindow fallback = new VideoWindow(capacity, 1000);
            fallback.useWirelessCapacity(); fallback.reserve(capacity * 3);
            fallback.useBluetoothCapacity();
            Future<?> resumed = executor.submit(() -> {
                try { fallback.reserve(capacity); } catch(IOException e) { throw new RuntimeException(e); }
            });
            fallback.acknowledge(capacity * 2);
            try { resumed.get(20, TimeUnit.MILLISECONDS); throw new AssertionError("Fallback ignored Classic capacity"); }
            catch(TimeoutException expected) {}
            fallback.acknowledge(capacity * 3); resumed.get(1, TimeUnit.SECONDS);
            if (fallback.inFlightBytes() != capacity) throw new AssertionError("Fallback reset cumulative accounting");
            fallback.close();
            System.out.println("VideoWindow: bounded backlog, cumulative ACK, validation, cancellation, stalled peer and Wi-Fi fallback capacity passed");
        } finally { executor.shutdownNow(); }
    }
}
