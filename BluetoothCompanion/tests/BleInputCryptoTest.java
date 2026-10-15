package app.droidmirror.bluetooth;
import java.io.*;
import java.nio.file.*;
import java.security.*;
import java.util.*;

public final class BleInputCryptoTest {
    private static void reject(BleInputCrypto crypto,byte[] packet) throws Exception {
        try { crypto.open(packet); throw new AssertionError("Accepted invalid packet"); }
        catch(GeneralSecurityException expected) {}
    }
    public static void main(String[] args) throws Exception {
        byte[] key=new byte[32]; for(int i=0;i<32;++i) key[i]=(byte)i;
        BleInputCrypto crypto=new BleInputCrypto(key);
        byte[] challenge=new byte[16];for(int i=0;i<16;++i) challenge[i]=(byte)i;
        byte[] proof=crypto.proof(challenge); StringBuilder hex=new StringBuilder();
        for(byte b:proof) hex.append(String.format("%02x",b));
        if(!hex.toString().equals("eaa36a8dcfebabd9da451687a4e0091f469c869592241b5ea604cef6a99ccd8d")) throw new AssertionError();
        List<byte[]> records=new ArrayList<>();
        try(DataInputStream in=new DataInputStream(Files.newInputStream(Paths.get(args[0])))) {
            while(in.available()>0) { byte[] record=new byte[in.readUnsignedShort()]; in.readFully(record); records.add(record); }
        }
        reject(crypto,records.get(1)); // Valid MAC, wrong sequence: do not advance state.
        byte[] bad=records.get(0).clone(); bad[8]^=1; reject(crypto,bad);
        reject(crypto,new byte[24]); reject(crypto,new byte[513]);
        for(int i=0;i<records.size();++i) {
            byte[] plain=crypto.open(records.get(i));
            for(int j=0;j<plain.length;++j) if(plain[j]!=(byte)(j+i)) throw new AssertionError("Cross-language payload mismatch");
            reject(crypto,records.get(i)); // Replays cannot be injected twice.
        }
        key[0]^=1; BleInputCrypto other=new BleInputCrypto(key); reject(other,records.get(0));
        System.out.println("BLE input crypto: Mac-to-Java chunks, tamper, replay, ordering, session isolation and bounds passed");
    }
}
