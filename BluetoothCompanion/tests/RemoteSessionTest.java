import app.droidmirror.bluetooth.RemoteSession;
import java.util.concurrent.atomic.AtomicLong;
import java.util.ArrayList;
import java.util.List;
public final class RemoteSessionTest {
    static void require(boolean ok) { if (!ok) throw new AssertionError(); }
    public static void main(String[] args) {
        AtomicLong clock = new AtomicLong(1);
        List<Integer> causes = new ArrayList<>();
        RemoteSession session = new RemoteSession(clock::get, (token, cause) -> { causes.add(cause); return true; });
        Object a = new Object(), b = new Object();
        require(session.begin(a)); session.tick(false);
        require(causes.equals(List.of(RemoteSession.LOCAL_USE)) && !session.owns(a));
        require(!session.finish(a, RemoteSession.APP_DIED)); // Power press + death/EOF emits one audit.
        require(session.begin(b)); require(!session.heartbeat(a)); require(!session.finish(a, RemoteSession.STOP));
        require(session.owns(b)); clock.addAndGet(2000); session.tick(true);
        require(causes.get(1) == RemoteSession.TIMEOUT && !session.heartbeat(b));
        require(session.begin(a)); require(session.finish(a, RemoteSession.APP_DIED));
        require(!session.finish(a, RemoteSession.STOP)); require(causes.size() == 3);
        require(session.begin(b)); require(session.finish(b, RemoteSession.STOP));
        require(session.begin(a, 10000)); clock.addAndGet(3000); session.tick(true); require(session.owns(a));
        require(session.heartbeat(a)); clock.addAndGet(2000); session.tick(true); require(!session.owns(a));
        System.out.println("RemoteSession: local-use precedence, crash/stop/timeout, stale owners and one end event per session passed");
    }
}
