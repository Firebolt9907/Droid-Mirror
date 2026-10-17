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
            // A replay can take longer than one timeout overall, provided ACKs
            // keep advancing. Duplicate heartbeats must not extend a real stall.
            VideoWindow replay = new VideoWindow(capacity, 150);
            replay.useWirelessCapacity(); replay.reserve(capacity * 6);
            replay.useBluetoothCapacity();
            Future<?> paced = executor.submit(() -> {
                try { replay.awaitBluetoothReplay(capacity * 6, 0); }
                catch(IOException e) { throw new RuntimeException(e); }
            });
            for (int i=1; i<=5; ++i) {
                Thread.sleep(60); replay.acknowledge(capacity*i);
            }
            paced.get(1, TimeUnit.SECONDS);
            if (replay.inFlightBytes()!=capacity) throw new AssertionError("Replay counted bytes twice");
            VideoWindow stalledReplay = new VideoWindow(capacity, 80);
            stalledReplay.useWirelessCapacity(); stalledReplay.reserve(capacity*2);
            stalledReplay.useBluetoothCapacity();
            Future<?> stalledReplayResult=executor.submit(() -> {
                try { stalledReplay.awaitBluetoothReplay(capacity*2,0); throw new AssertionError("Stalled replay continued"); }
                catch(IOException expected) {}
            });
            for (int i=0; i<5; ++i) { Thread.sleep(30); stalledReplay.acknowledge(0); }
            stalledReplayResult.get(1,TimeUnit.SECONDS);
            System.out.println("VideoWindow: bounded backlog, cumulative ACK, validation, cancellation, stalled peer and Wi-Fi fallback capacity passed");
        } finally { executor.shutdownNow(); }
    }
}
