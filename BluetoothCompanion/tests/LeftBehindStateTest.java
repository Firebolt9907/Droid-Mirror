import app.droidmirror.bluetooth.LeftBehindState;

public class LeftBehindStateTest {
    private static void check(boolean value) { if (!value) throw new AssertionError(); }
    public static void main(String[] args) {
        LeftBehindState state = new LeftBehindState();
        state.motion(1000); state.disconnected(2000);
        check(!state.shouldNotify(50_000)); // Unauthenticated disconnect never arms.
        state.present(); state.disconnected(60_000);
        check(!state.shouldNotify(106_000)); // Stationary phone.
        state.motion(107_000);
        check(state.shouldNotify(107_000));
        check(!state.shouldNotify(110_000)); // One alert per separation.
        state.present(); state.motion(120_000); state.disconnected(121_000);
        check(!state.shouldNotify(165_999));
        check(state.shouldNotify(166_000)); // Motion preceding disconnect counts.
        state.present(); state.disconnected(170_000); state.present();
        check(!state.shouldNotify(220_000)); // Reconnection cancels.
        state.disconnected(230_000); state.reset(); state.motion(240_000);
        check(!state.shouldNotify(290_000)); // Stop, trust reset, or local Bluetooth off.
        state.present(); state.disconnected(300_000); state.motion(910_000);
        check(!state.shouldNotify(910_000)); // Old absence cannot alert hours later.
        state.present(); state.disconnected(1_000_000);
        check(!state.shouldNotify(1_045_000)); // Stale motion from previous session.
        System.out.println("LeftBehindState tests passed");
    }
}
