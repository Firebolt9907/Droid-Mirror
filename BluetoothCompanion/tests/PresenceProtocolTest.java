import app.droidmirror.bluetooth.PresenceProtocol;
public final class PresenceProtocolTest {
    public static void main(String[] args) throws Exception {
        byte[] key = new byte[32];
        for (int i=0;i<key.length;i++) key[i]=(byte)i;
        if (!PresenceProtocol.beacon(key).toString().equals("ead9602c-8e88-8334-828d-e6cf50915a14")) throw new AssertionError();
        if (PresenceProtocol.beacon(key).equals(PresenceProtocol.beacon(new byte[32]))) throw new AssertionError();
        try { PresenceProtocol.beacon(new byte[31]); throw new AssertionError(); }
        catch (java.security.GeneralSecurityException expected) {}
        System.out.println("PASS: original #2 beacon UUID preserved; distinct pairing and invalid-key checks");
    }
}
