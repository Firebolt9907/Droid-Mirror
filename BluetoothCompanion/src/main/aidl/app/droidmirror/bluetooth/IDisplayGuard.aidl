package app.droidmirror.bluetooth;

interface IDisplayGuard {
    boolean acquire(IBinder owner) = 1;
    boolean heartbeat(IBinder owner) = 2;
    boolean release(IBinder owner) = 3;
    boolean restoreDisplay() = 4;
    String getLastError() = 5;
    void destroy() = 16777114;
}
