package app.droidmirror.bluetooth;

interface IHotspotBridge {
    String startHotspot() = 1;
    void destroy() = 16777114;
}
