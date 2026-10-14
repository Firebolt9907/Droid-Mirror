package app.droidmirror.bluetooth;

oneway interface IStreamEvents {
    void onEnded(int cause, boolean lockedAndAwake);
}
