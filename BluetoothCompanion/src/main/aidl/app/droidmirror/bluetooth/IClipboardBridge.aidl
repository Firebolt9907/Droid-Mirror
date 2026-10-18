package app.droidmirror.bluetooth;

interface IClipboardBridge {
    String readText() = 1;
    boolean writeText(String text) = 2;
    String getStatus() = 3;
    String readToken() = 4;
    String readFileInfo() = 5;
    byte[] readFileChunk(String uri, int offset) = 6;
    boolean writeFile(String uri, String expectedToken) = 7;
    void destroy() = 16777114;
}
