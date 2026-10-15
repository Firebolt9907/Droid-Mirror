package app.droidmirror.bluetooth;
import android.os.ParcelFileDescriptor;

interface IClassicL2cap {
    boolean listen(IBinder owner, String peer) = 1;
    ParcelFileDescriptor accept(IBinder owner) = 2;
    void disconnect(IBinder owner) = 3;
    void stop(IBinder owner) = 4;
    String getLastError() = 5;
    void destroy() = 16777114;
}
