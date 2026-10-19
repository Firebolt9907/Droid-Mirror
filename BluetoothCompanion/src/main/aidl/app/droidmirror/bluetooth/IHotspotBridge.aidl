package app.droidmirror.bluetooth;

interface IHotspotBridge {
    String startHotspot() = 1;
    String stopHotspot() = 2;
    String hotspotSSID() = 3;
    void destroy() = 16777114;
}
