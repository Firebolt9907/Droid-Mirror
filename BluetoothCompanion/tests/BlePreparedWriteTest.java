package app.droidmirror.bluetooth;
import java.util.Arrays;
import java.io.IOException;
import java.security.GeneralSecurityException;

public final class BlePreparedWriteTest {
    static void check(boolean value) { if (!value) throw new AssertionError(); }
    public static void main(String[] args) throws Exception {
        byte[] key=new byte[32], plain=new byte[488];
        for (int i=0;i<plain.length;i++) plain[i]=(byte)i;
        BleInputCrypto sender=new BleInputCrypto(key), receiver=new BleInputCrypto(key);
        byte[] packet=sender.seal(plain);
        BlePreparedWrite transaction=new BlePreparedWrite();
        for (int offset=0;offset<packet.length;) {
            int end=Math.min(packet.length,offset+18); // Minimum-MTU prepare chunks.
            byte[] fragment=Arrays.copyOfRange(packet,offset,end);
            check(transaction.prepare(offset,fragment));
            check(transaction.prepare(offset,fragment)); // Exact ATT retry is harmless.
            offset=end;
        }
        byte[] complete=transaction.commit(); check(Arrays.equals(complete,packet));
        check(Arrays.equals(receiver.open(complete),plain));
        check(transaction.commit()==null); // Execute cannot replay a transaction.
        try { receiver.open(complete); throw new AssertionError("Replay accepted"); }
        catch (GeneralSecurityException expected) { }
        transaction=new BlePreparedWrite(); check(!transaction.prepare(1,new byte[18])); check(transaction.commit()==null);
        transaction=new BlePreparedWrite(); check(transaction.prepare(0,new byte[18]));
        check(!transaction.prepare(0,new byte[]{1})); check(transaction.commit()==null);
        transaction=new BlePreparedWrite(); check(!transaction.prepare(0,new byte[513])); check(transaction.commit()==null);
        transaction=new BlePreparedWrite(); check(transaction.prepare(0,new byte[24])); check(transaction.commit()==null);
        // Discarding a prepared transaction (ATT cancel/disconnect) consumes no
        // cryptographic sequence. Its record remains valid in a new transaction.
        byte[] next=sender.seal(new byte[]{7});
        transaction=new BlePreparedWrite(); check(transaction.prepare(0,next));
        transaction=new BlePreparedWrite(); check(transaction.prepare(0,next));
        check(Arrays.equals(receiver.open(transaction.commit()),new byte[]{7}));
        byte[] bad=sender.seal(new byte[]{8}); bad[8]^=1;
        transaction=new BlePreparedWrite(); check(transaction.prepare(0,bad));
        try { receiver.open(transaction.commit()); throw new AssertionError("Tampering accepted"); }
        catch (GeneralSecurityException expected) { }
        BleInputCommandStream stream=new BleInputCommandStream();
        byte[] framed=new byte[packet.length+2]; framed[0]=(byte)(packet.length>>8); framed[1]=(byte)packet.length;
        System.arraycopy(packet,0,framed,2,packet.length);
        BleInputCrypto commandReceiver=new BleInputCrypto(key);
        byte[] assembled=null;
        for (int offset=0;offset<framed.length;offset+=20) {
            byte[] part=Arrays.copyOfRange(framed,offset,Math.min(framed.length,offset+20));
            assembled=stream.append(part);
            if (offset+20<framed.length) check(assembled==null);
        }
        check(Arrays.equals(commandReceiver.open(assembled),plain));
        try { new BleInputCommandStream().append(new byte[]{0,24}); throw new AssertionError(); }
        catch (IOException expected) { }
        System.out.println("BLE prepared writes: minimum-MTU fragmentation, 512-byte bound, duplicate fragments, commit once, cancellation, tampering and sequence checks passed");
    }
}
