package app.droidmirror.bluetooth;

import java.util.concurrent.*;
import java.util.concurrent.atomic.AtomicInteger;

public final class SessionEndDeliveryTest {
    public static void main(String[] args) throws Exception {
        // Both pipe EOFs arrive before the shell finishes restoring the display.
        SessionEndDelivery ending = new SessionEndDelivery();
        CountDownLatch waiting = new CountDownLatch(2), transmitting = new CountDownLatch(1), release = new CountDownLatch(1);
        AtomicInteger sends = new AtomicInteger(), closed = new AtomicInteger();
        ExecutorService workers = Executors.newFixedThreadPool(2);
        try {
            Callable<Boolean> eof = () -> {
                waiting.countDown();
                boolean delivered = ending.sendPending(event -> {
                    if (event != BluetoothWire.PHONE_ON) throw new AssertionError();
                    sends.incrementAndGet(); transmitting.countDown();
                    try { if (!release.await(1, TimeUnit.SECONDS)) throw new AssertionError(); }
                    catch (InterruptedException e) { throw new AssertionError(e); }
                }, 1000);
                closed.incrementAndGet(); return delivered;
            };
            Future<Boolean> capture = workers.submit(eof), controls = workers.submit(eof);
            if (!waiting.await(1, TimeUnit.SECONDS)) throw new AssertionError();
            if (closed.get() != 0) throw new AssertionError("EOF must wait for the end reason");
            if (!ending.signal(BluetoothWire.PHONE_ON)) throw new AssertionError();
            if (ending.signal(BluetoothWire.SESSION_ENDED)) throw new AssertionError("Preserve the original cause");
            if (!transmitting.await(1, TimeUnit.SECONDS)) throw new AssertionError();
            if (closed.get() != 0) throw new AssertionError("Neither reader may close BLE during the end-event send");
            release.countDown();
            if (!capture.get(1, TimeUnit.SECONDS) || !controls.get(1, TimeUnit.SECONDS) || sends.get() != 1 || closed.get() != 2)
                throw new AssertionError("Send once, then allow both EOF readers to close");
            SessionEndDelivery broken = new SessionEndDelivery();
            long start = System.nanoTime();
            if (broken.sendPending(event -> { throw new AssertionError(); }, 30)) throw new AssertionError();
            if (System.nanoTime() - start > TimeUnit.SECONDS.toNanos(1)) throw new AssertionError("Transport failures must time out");
        } finally { release.countDown(); workers.shutdownNow(); }
        System.out.println("PASS: capture/control EOF waits for phone power event; concurrent sends drain once; missing events time out");
    }
}
