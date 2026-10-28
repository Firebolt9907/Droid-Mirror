package app.droidmirror.bluetooth;
import java.io.ByteArrayOutputStream;
import java.io.IOException;

/** Length-prefixed ciphertext for small-MTU ATT commands. Authentication follows reassembly. */
final class BleInputCommandStream {
    private final ByteArrayOutputStream bytes=new ByteArrayOutputStream();
    private int expected=-1;
    byte[] append(byte[] fragment) throws IOException {
        if (fragment==null || fragment.length==0 || bytes.size()+fragment.length>514)
            throw new IOException("Invalid BLE command fragment");
        bytes.write(fragment,0,fragment.length);
        byte[] current=bytes.toByteArray();
        if (expected<0 && current.length>=2) {
            expected=((current[0]&255)<<8)|(current[1]&255);
            if (expected<=24 || expected>512) throw new IOException("Invalid BLE command length");
        }
        if (expected<0 || current.length<expected+2) return null;
        if (current.length!=expected+2) throw new IOException("BLE command overflow");
        byte[] packet=java.util.Arrays.copyOfRange(current,2,current.length);
        bytes.reset(); expected=-1; return packet;
    }
}
