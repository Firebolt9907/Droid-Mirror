package app.droidmirror.bluetooth;

interface IClipboardBridge {
    String readText() = 1;
    boolean writeText(String text) = 2;
    String getStatus() = 3;
    void destroy() = 16777114;
}
