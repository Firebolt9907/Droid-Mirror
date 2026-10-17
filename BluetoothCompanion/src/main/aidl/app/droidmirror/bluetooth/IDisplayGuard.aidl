package app.droidmirror.bluetooth;

import app.droidmirror.bluetooth.IStreamEvents;
import android.os.ParcelFileDescriptor;

interface IDisplayGuard {
    boolean acquire(IBinder owner, IStreamEvents observer, boolean panelOff) = 1;
    boolean heartbeat(IBinder owner) = 2;
    boolean release(IBinder owner) = 3;
    boolean restoreDisplay() = 4;
    String getLastError() = 5;
    boolean startCapture(IBinder owner, IStreamEvents observer, in ParcelFileDescriptor output, in ParcelFileDescriptor controls) = 6;
    void localUse(IBinder owner) = 7;
    boolean upgradeVideo(IBinder owner, int maxSize, int fps, int bitRate) = 8;
    boolean restoreBluetoothVideo(IBinder owner) = 9;
    boolean grantSecureSettings() = 10;
    byte[] phoneAppearance() = 11;
    void destroy() = 16777114;
}
