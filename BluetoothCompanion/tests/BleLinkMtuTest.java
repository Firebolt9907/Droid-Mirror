import app.droidmirror.bluetooth.BleLinkMtu;

public final class BleLinkMtuTest {
    public static void main(String[] args) {
        String phone = "paired-mac", stranger = "other-mac";
        // Notification service negotiates before the first input server exists.
        BleLinkMtu.negotiated(phone, 517);
        if (BleLinkMtu.get(phone) != 517 || BleLinkMtu.get(stranger) != 23) throw new AssertionError("Shared link MTU lost or leaked to another peer");
        // Closing/recreating an input server does not imply link disconnection.
        if (BleLinkMtu.get(phone) - 3 - 24 <= 0) throw new AssertionError("Reconnect cannot carry an encrypted return record");
        BleLinkMtu.negotiated(phone, 0);
        if (BleLinkMtu.get(phone) != 517) throw new AssertionError("Invalid callback replaced negotiated MTU");
        BleLinkMtu.disconnected(phone);
        if (BleLinkMtu.get(phone) != 23) throw new AssertionError("Stale MTU survived physical disconnection");
        BleLinkMtu.observedWrite(phone, 40);
        if (BleLinkMtu.get(phone) != 43) throw new AssertionError("Reused link without MTU callback cannot send returns");
        BleLinkMtu.observedWrite(phone, 30);
        if (BleLinkMtu.get(phone) != 43) throw new AssertionError("Shorter write reduced known capacity");
        BleLinkMtu.negotiated(phone, 64);
        if (BleLinkMtu.get(phone) != 64) throw new AssertionError("New link MTU not used");
        // The notification server rejoins a link negotiated by input and can
        // also infer capacity from its own non-prepared authentication write.
        BleLinkMtu.observedWrite(phone, 82);
        if (BleLinkMtu.get(phone) - 3 != 82) throw new AssertionError("Notification handshake fell back to 20-byte fragments");
        BleLinkMtu.negotiated(phone, 517);
        BleLinkMtu.observedWrite(phone, 37);
        if (BleLinkMtu.get(phone) != 517) throw new AssertionError("Short input ACK shrank notification MTU");
        System.out.println("PASS: notification-to-input MTU reuse, peer isolation, disconnect and renegotiation");
    }
}
