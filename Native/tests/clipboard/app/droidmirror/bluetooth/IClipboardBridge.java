package app.droidmirror.bluetooth;
interface IClipboardBridge {
    String readToken();
    String readFileInfo() throws Exception;
    byte[] readFileChunk(String uri, int offset);
    boolean writeFile(String uri, String expectedToken);
}
