import app.droidmirror.bluetooth.CameraFrameWindow;

public final class CameraFrameWindowTest {
    static void require(boolean value) { if (!value) throw new AssertionError(); }
    public static void main(String[] args) {
        CameraFrameWindow window = new CameraFrameWindow();
        window.sent(1, 0); window.sent(2, 67); window.sent(3, 134);
        require(!window.available(200));
        window.acknowledge(99); require(!window.available(200));
        window.acknowledge(2); require(window.available(200)); // ACKs may arrive out of order.
        window.sent(4, 201); require(!window.available(2999));
        require(window.available(3000)); // Lost ACKs recover, bounded to three seconds.
        window.sent(5, 3000); require(!window.available(3000));
        window.clear(); require(window.available(3000));
        System.out.println("Camera ACK window tests passed");
    }
}
