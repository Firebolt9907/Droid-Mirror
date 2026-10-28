package app.droidmirror.bluetooth;

oneway interface IStreamEvents {
    void onUnlockConfirmed();
    void onEnded(int cause, boolean lockedAndAwake);
    void onHaptic();
}
