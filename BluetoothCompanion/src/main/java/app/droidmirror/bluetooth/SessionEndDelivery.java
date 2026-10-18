package app.droidmirror.bluetooth;

import java.io.IOException;
import java.util.concurrent.CountDownLatch;
import java.util.concurrent.TimeUnit;
import java.util.concurrent.atomic.AtomicInteger;

/** Keep the side channel alive while the shell reports why capture/control EOF occurred. */
final class SessionEndDelivery {
    interface Sender { void send(int event) throws IOException; }
    private final AtomicInteger event = new AtomicInteger();
    private final CountDownLatch ready = new CountDownLatch(1);
    private boolean sent;

    int get() { return event.get(); }
    boolean signal(int value) {
        if (!event.compareAndSet(0, value)) return false;
        ready.countDown();
        return true;
    }
    boolean sendPending(Sender sender, long timeoutMillis) throws IOException, InterruptedException {
        if (!ready.await(timeoutMillis, TimeUnit.MILLISECONDS)) return false;
        // Capture EOF and control EOF can race. The loser waits for the BLE send
        // to complete, so it cannot close the transport underneath the winner.
        synchronized (this) {
            if (!sent) {
                sent = true;
                sender.send(event.get());
            }
        }
        return true;
    }
}
