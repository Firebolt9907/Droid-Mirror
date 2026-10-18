package app.droidmirror.bluetooth;

import android.content.Context;
import org.json.JSONObject;
import java.nio.file.Files;
import java.nio.file.Path;
import java.util.ArrayList;
import java.util.Arrays;
import java.util.UUID;

public final class ClipboardFileTransferTest {
    private static void check(boolean value) { if (!value) throw new AssertionError(); }
    private static final class Bridge implements IClipboardBridge {
        String token = "initial", written;
        byte[] source;
        int advertisedSize;
        @Override public String readToken() { return token; }
        @Override public String readFileInfo() throws Exception {
            return source == null ? null : new JSONObject().put("name", "phone.bin").put("size", advertisedSize).put("uri", "content://source/file").toString();
        }
        @Override public byte[] readFileChunk(String uri, int offset) {
            return Arrays.copyOfRange(source, offset, Math.min(source.length, offset + ClipboardFilePolicy.CHUNK));
        }
        @Override public boolean writeFile(String uri, String expected) {
            if (!expected.equals(token)) return false;
            written = uri; token = UUID.randomUUID().toString(); return true;
        }
    }
    private static JSONObject event(String type, String id, int offset) throws Exception {
        return new JSONObject().put("type", type).put("id", id).put("offset", offset);
    }
    public static void main(String[] args) throws Exception {
        Path cache = Files.createTempDirectory(Path.of("/private/tmp"), "android-clipboard-files-");
        try {
            ArrayList<JSONObject> events = new ArrayList<>();
            ClipboardFileTransfer files = new ClipboardFileTransfer(new Context(cache.toFile()), events::add);
            Bridge bridge = new Bridge();
            files.poll(bridge); check(events.isEmpty()); // no pre-existing upload
            bridge.source = new byte[7000];
            for (int i = 0; i < bridge.source.length; i++) bridge.source[i] = (byte) (i % 251);
            bridge.advertisedSize = bridge.source.length; bridge.token = "copied";
            files.poll(bridge);
            String id = events.getLast().getString("id");
            check(events.getLast().getString("type").equals("clipboardFileBegin"));
            java.io.ByteArrayOutputStream sent = new java.io.ByteArrayOutputStream();
            while (sent.size() < bridge.source.length) {
                files.receive(event("clipboardFileAck", id, sent.size()), bridge);
                JSONObject chunk = events.getLast();
                check(chunk.getString("type").equals("clipboardFileChunk"));
                sent.write(java.util.Base64.getUrlDecoder().decode(chunk.getString("data")));
            }
            check(Arrays.equals(sent.toByteArray(), bridge.source));
            files.receive(event("clipboardFileAck", id, sent.size()), bridge);
            int count = events.size();
            bridge.advertisedSize = 5_000_000; bridge.token = "too large"; files.poll(bridge);
            check(events.size() == count);
            bridge.advertisedSize = 10; bridge.token = "lying provider"; files.poll(bridge);
            check(events.size() == count); // actual bytes do not match provider metadata
            for (int size : new int[]{0, 1, 4_999_999}) {
                bridge.source = null;
                id = UUID.randomUUID().toString();
                files.receive(event("clipboardFileBegin", id, 0).put("name", "received.bin").put("size", size), bridge);
                byte[] data = new byte[size]; Arrays.fill(data, (byte) 42);
                for (int offset = 0; offset < size; offset += ClipboardFilePolicy.CHUNK) {
                    byte[] chunk = Arrays.copyOfRange(data, offset, Math.min(size, offset + ClipboardFilePolicy.CHUNK));
                    files.receive(event("clipboardFileChunk", id, offset).put("data", java.util.Base64.getEncoder().encodeToString(chunk)), bridge);
                }
                check(events.getLast().getString("type").equals("clipboardFileAck"));
                check(events.getLast().getInt("offset") == size);
                String path = java.net.URI.create(bridge.written).getPath();
                check(Arrays.equals(Files.readAllBytes(cache.resolve("clipboard-files").resolve(path.substring(1))), data));
                count = events.size(); files.poll(bridge); check(events.size() == count); // no echo
            }
            String previous = bridge.written;
            id = UUID.randomUUID().toString();
            files.receive(event("clipboardFileBegin", id, 0).put("name", "../escape").put("size", 1), bridge);
            check(events.getLast().getString("type").equals("clipboardFileCancel"));
            files.receive(event("clipboardFileBegin", id, 0).put("name", "x").put("size", 5_000_000), bridge);
            check(events.getLast().getString("type").equals("clipboardFileCancel"));
            files.receive(event("clipboardFileBegin", id, 0).put("name", "x").put("size", 1), bridge);
            files.receive(event("clipboardFileChunk", id, 1).put("data", "YQ=="), bridge);
            check(events.getLast().getString("type").equals("clipboardFileCancel"));
            files.receive(event("clipboardFileBegin", id, 0).put("name", "x").put("size", 1), bridge);
            bridge.token = "new local copy";
            files.receive(event("clipboardFileChunk", id, 0).put("data", "YQ=="), bridge);
            check(events.getLast().getString("type").equals("clipboardFileCancel"));
            check(previous.equals(bridge.written));
            files.poll(bridge);
            files.receive(event("clipboardFileBegin", id, 0).put("name", "x").put("size", 1), bridge);
            files.reset(); // disconnect or lock
            files.receive(event("clipboardFileChunk", id, 0).put("data", "YQ=="), bridge);
            check(previous.equals(bridge.written));
            System.out.println("Android file clipboard transfer tests passed");
        } finally {
            try (var paths = Files.walk(cache)) {
                for (Path path : paths.sorted(java.util.Comparator.reverseOrder()).toList()) Files.delete(path);
            }
        }
    }
}
