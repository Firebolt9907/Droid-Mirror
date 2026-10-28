package app.droidmirror.bluetooth;

import java.io.ByteArrayOutputStream;
import java.util.Arrays;

/** One bounded ATT reliable-write transaction; no input executes before commit. */
final class BlePreparedWrite {
    private final ByteArrayOutputStream bytes=new ByteArrayOutputStream();
    private boolean invalid;
    synchronized boolean prepare(int offset, byte[] fragment) {
        if (invalid) return false;
        if (fragment==null || fragment.length==0 || offset<0 || offset>bytes.size()
                || fragment.length>512-offset) {
            invalid=true; return false;
        }
        if (offset<bytes.size()) {
            byte[] current=bytes.toByteArray();
            if (offset+fragment.length>current.length
                    || !Arrays.equals(Arrays.copyOfRange(current,offset,offset+fragment.length),fragment)) {
                invalid=true; return false;
            }
            return true; // Identical prepare retry does not duplicate ciphertext.
        }
        bytes.write(fragment,0,fragment.length);
        return true;
    }
    synchronized byte[] commit() {
        byte[] result=invalid || bytes.size()<=24 ? null : bytes.toByteArray();
        bytes.reset(); invalid=false;
        return result;
    }
}
