import app.droidmirror.bluetooth.PresenceProtocol;
import java.util.Arrays;
import java.util.HexFormat;
public final class PresenceProtocolTest {
    static void check(boolean value) { if (!value) throw new AssertionError(); }
    public static void main(String[] args) throws Exception {
        byte[] key = new byte[32], nonce = new byte[16];
        for (int i=0;i<key.length;i++) key[i]=(byte)i;
        for (int i=0;i<nonce.length;i++) nonce[i]=(byte)i;
        check(PresenceProtocol.uuid(key, "DroidMirror presence beacon v1").toString().equals("ead9602c-8e88-8334-828d-e6cf50915a14"));
        check(PresenceProtocol.uuid(key, "DroidMirror presence classic v1").toString().equals("ad802dda-cdf9-8f79-b8ec-adb1e0abfaea"));
        byte[] gatt=PresenceProtocol.proof(key,"gatt",nonce), classic=PresenceProtocol.proof(key,"classic",nonce);
        check(HexFormat.of().formatHex(gatt).equals("65f66f4793b46a6a14149d66edadf461e5e64aeeab7721dce36a121614c6a8d1"));
        check(HexFormat.of().formatHex(classic).equals("35c4af40d8cce7e4696f7ef7a809c285a99d45a4f117f968c186305061470fae"));
        check(!Arrays.equals(gatt,classic));
        nonce[0]++;
        check(!Arrays.equals(gatt,PresenceProtocol.proof(key,"gatt",nonce)));
        key[0]++;
        check(!Arrays.equals(classic,PresenceProtocol.proof(key,"classic",nonce)));
        try { PresenceProtocol.proof(key,"gatt",new byte[15]); throw new AssertionError(); } catch (java.security.GeneralSecurityException expected) {}
        try { PresenceProtocol.proof(key,"mac",nonce); throw new AssertionError(); } catch (java.security.GeneralSecurityException expected) {}
        System.out.println("Presence protocol vectors, nonce freshness and domain separation passed");
    }
}
