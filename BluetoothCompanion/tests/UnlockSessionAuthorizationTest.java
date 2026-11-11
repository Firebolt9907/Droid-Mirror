package app.droidmirror.bluetooth;

public final class UnlockSessionAuthorizationTest {
    static byte[] decision(int value) { return new byte[] {0x71,0,0,0,1,(byte)value}; }
    static void check(boolean value) { if (!value) throw new AssertionError(); }
    public static void main(String[] args) throws Exception {
        UnlockSessionAuthorization approved = new UnlockSessionAuthorization();
        check(!approved.allowed());
        approved.firstRecord(decision(1)); check(approved.allowed());
        approved.firstRecord(decision(0)); check(approved.allowed());
        UnlockSessionAuthorization cancelled = new UnlockSessionAuthorization();
        cancelled.firstRecord(decision(0)); check(!cancelled.allowed());
        cancelled.firstRecord(decision(1)); check(!cancelled.allowed());
        for (byte[] invalid : new byte[][] {new byte[0], decision(2), new byte[] {1,0,0,0,0},
                new byte[] {0x71,0,0,0,2,1}, new byte[] {0x71,0,0,0,1,1,0}}) {
            UnlockSessionAuthorization denied = new UnlockSessionAuthorization();
            denied.firstRecord(invalid); check(!denied.allowed());
            denied.firstRecord(decision(1)); check(!denied.allowed());
        }
        check(!new UnlockSessionAuthorization().allowed()); // No cross-session reuse.
        byte[] key = new byte[32];
        BleInputCrypto sender = new BleInputCrypto(key);
        byte[] grant = sender.seal(decision(1));
        BleInputCrypto receiver = new BleInputCrypto(key);
        UnlockSessionAuthorization secured = new UnlockSessionAuthorization();
        secured.firstRecord(receiver.open(grant)); check(secured.allowed());
        try { receiver.open(grant); throw new AssertionError("Replay accepted"); }
        catch (java.security.GeneralSecurityException expected) { }
        byte[] otherKey = new byte[32]; otherKey[0] = 1;
        try { new BleInputCrypto(otherKey).open(grant); throw new AssertionError("Cross-session grant accepted"); }
        catch (java.security.GeneralSecurityException expected) { }
        grant[grant.length - 1] ^= 1;
        try { new BleInputCrypto(key).open(grant); throw new AssertionError("Tamper accepted"); }
        catch (java.security.GeneralSecurityException expected) { }
        System.out.println("Unlock session: approval, cancellation, malformed/legacy input and late-grant rejection passed");
    }
}
