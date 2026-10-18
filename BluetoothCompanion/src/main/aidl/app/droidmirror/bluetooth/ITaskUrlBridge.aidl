package app.droidmirror.bluetooth;

interface ITaskUrlBridge {
    String readTask() = 1;
    boolean openBrowser(String url) = 2;
    void destroy() = 16777114;
}
