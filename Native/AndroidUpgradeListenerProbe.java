import android.net.LocalServerSocket;
import android.system.Os;
import android.system.OsConstants;
import java.util.concurrent.*;

/** Run on Android: exercise the real blocking accept and abstract-name reuse. */
public final class AndroidUpgradeListenerProbe {
    public static void main(String[] args) throws Exception {
        String name="droidmirror_teardown_test_"+android.os.Process.myPid();
        ExecutorService workers=Executors.newSingleThreadExecutor();
        try {
            for(int i=0;i<30;i++) {
                LocalServerSocket listener=new LocalServerSocket(name);
                CountDownLatch accepting=new CountDownLatch(1);
                Future<?> accepted=workers.submit(() -> {
                    accepting.countDown();
                    try { listener.accept().close(); throw new AssertionError("Unexpected connection"); }
                    catch(java.io.IOException stopped) { }
                });
                accepting.await(); Thread.sleep(10);
                Os.shutdown(listener.getFileDescriptor(),OsConstants.SHUT_RDWR);
                listener.close();
                accepted.get(1,TimeUnit.SECONDS);
            }
            System.out.println("PASS: 30 Android blocking accepts cancelled and abstract endpoint rebound");
        } finally { workers.shutdownNow(); }
    }
}
