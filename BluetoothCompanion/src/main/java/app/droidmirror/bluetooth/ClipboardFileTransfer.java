package app.droidmirror.bluetooth;

import android.content.Context;
import android.content.Intent;
import android.net.Uri;
import android.os.SystemClock;
import android.util.Base64;
import org.json.JSONObject;
import java.io.ByteArrayOutputStream;
import java.io.File;
import java.nio.file.Files;
import java.util.UUID;
import java.util.function.Consumer;

/** Serialized on ClipboardSyncClient's worker. One bounded, negotiated-window transfer per direction. */
final class ClipboardFileTransfer {
    private final Context context;
    private final Consumer<JSONObject> events;
    private String baseline;
    private boolean sampled;
    private String outgoing;
    private byte[] outgoingData;
    private int outgoingSize, sentOffset;
    private String incoming, incomingName, incomingToken;
    private int incomingSize;
    private int incomingWindow, outgoingWindow, chunksSinceAck;
    private ByteArrayOutputStream bytes;
    private long sentAt, receivedAt;

    ClipboardFileTransfer(Context context, Consumer<JSONObject> events) {
        this.context = context;
        this.events = events;
    }
    private void emit(String type, String id, int offset) throws Exception {
        events.accept(new JSONObject().put("type", type).put("id", id).put("offset", offset));
    }
    private void cancelIncoming() throws Exception {
        if (incoming != null) emit("clipboardFileCancel", incoming, 0);
        incoming = null; bytes = null;
    }
    private void cancelOutgoing() throws Exception {
        if (outgoing != null) emit("clipboardFileCancel", outgoing, 0);
        outgoing = null; outgoingData = null;
    }
    void reset() {
        baseline = null; sampled = false; outgoing = null; outgoingData = null; incoming = null; bytes = null;
    }
    void textApplied(IClipboardBridge service) {
        try {
            cancelIncoming();
            cancelOutgoing();
            String token = service.readToken();
            if (token != null) {
                baseline = token;
                sampled = true;
            }
        } catch (Exception ignored) {}
    }
    void poll(IClipboardBridge service) throws Exception {
        long now = SystemClock.elapsedRealtime();
        if (outgoing != null && now - sentAt > 60_000) cancelOutgoing();
        if (incoming != null && now - receivedAt > 60_000) cancelIncoming();
        String token = service.readToken();
        if (token == null) { reset(); return; }
        boolean changed = sampled && !token.equals(baseline);
        sampled = true; baseline = token;
        if (!changed) return;
        cancelIncoming(); cancelOutgoing();
        String info = service.readFileInfo();
        if (info == null) return;
        JSONObject file = new JSONObject(info);
        int size = file.getInt("size"); String name = file.getString("name");
        if (!ClipboardFilePolicy.allowed(size) || !ClipboardFilePolicy.nameAllowed(name)) return;
        // Snapshot before advertising: validate actual bytes as well as provider metadata.
        ByteArrayOutputStream snapshot = new ByteArrayOutputStream();
        while (true) {
            if (!token.equals(service.readToken())) return;
            byte[] part = service.readFileChunk(file.getString("uri"), snapshot.size());
            if (part == null || part.length > ClipboardFilePolicy.CHUNK
                    || snapshot.size() + part.length > size) return;
            if (part.length == 0) break;
            snapshot.write(part);
        }
        if (snapshot.size() != size) return;
        outgoing = UUID.randomUUID().toString(); outgoingData = snapshot.toByteArray();
        outgoingSize = size; sentOffset = 0; sentAt = now;
        events.accept(new JSONObject().put("type", "clipboardFileBegin").put("id", outgoing).put("name", name).put("size", size).put("window", ClipboardFilePolicy.WINDOW));
    }
    void receive(JSONObject event, IClipboardBridge service) throws Exception {
        String type = event.optString("type"), id = event.optString("id");
        if (!id.matches("[a-fA-F0-9-]{36}")) return;
        if (type.equals("clipboardFileCancel")) {
            if (id.equals(incoming)) { incoming = null; bytes = null; }
            if (id.equals(outgoing)) { outgoing = null; outgoingData = null; }
        } else if (type.equals("clipboardFileBegin")) {
            cancelIncoming();
            long size = event.optLong("size", -1); String name = event.optString("name");
            String token = service.readToken();
            if (!ClipboardFilePolicy.allowed(size) || !ClipboardFilePolicy.nameAllowed(name)
                    || token == null || !sampled || !token.equals(baseline)) {
                emit("clipboardFileCancel", id, 0); return;
            }
            cancelOutgoing();
            incoming = id; incomingName = name; incomingSize = (int) size; incomingToken = token;
            incomingWindow = Math.max(1, Math.min(event.optInt("window", 1), ClipboardFilePolicy.WINDOW));
            chunksSinceAck = 0;
            bytes = new ByteArrayOutputStream(); receivedAt = SystemClock.elapsedRealtime();
            if (size == 0) complete(service);
            else events.accept(new JSONObject().put("type", "clipboardFileAck").put("id", id).put("offset", 0).put("window", incomingWindow));
        } else if (type.equals("clipboardFileChunk") && id.equals(incoming)) {
            if (!incomingToken.equals(service.readToken()) || event.optInt("offset", -1) != bytes.size()) {
                cancelIncoming(); return;
            }
            String encoded = event.optString("data");
            if (encoded.length() > 4096) { cancelIncoming(); return; }
            byte[] chunk;
            try { chunk = Base64.decode(encoded.replace('-', '+').replace('_', '/'), Base64.NO_WRAP); }
            catch (IllegalArgumentException failure) { cancelIncoming(); return; }
            if (chunk.length == 0 || chunk.length > ClipboardFilePolicy.CHUNK || bytes.size() + chunk.length > incomingSize) {
                cancelIncoming(); return;
            }
            bytes.write(chunk); receivedAt = SystemClock.elapsedRealtime();
            chunksSinceAck++;
            if (bytes.size() == incomingSize) complete(service);
            else if (chunksSinceAck == incomingWindow) { chunksSinceAck = 0; emit("clipboardFileAck", id, bytes.size()); }
        } else if (type.equals("clipboardFileAck") && id.equals(outgoing)) {
            if (event.optInt("offset", -1) != sentOffset || !baseline.equals(service.readToken())) {
                cancelOutgoing(); return;
            }
            if (sentOffset == outgoingSize) {
                outgoing = null; outgoingData = null; return;
            }
            if (sentOffset == 0) outgoingWindow = Math.max(1, Math.min(event.optInt("window", 1), ClipboardFilePolicy.WINDOW));
            for (int i = 0; i < outgoingWindow; i++) {
                int wanted = Math.min(ClipboardFilePolicy.CHUNK, outgoingSize - sentOffset);
                byte[] chunk = java.util.Arrays.copyOfRange(outgoingData, sentOffset, sentOffset + wanted);
                events.accept(new JSONObject().put("type", "clipboardFileChunk").put("id", id).put("offset", sentOffset)
                    .put("data", Base64.encodeToString(chunk, Base64.NO_WRAP).replace('+', '-').replace('/', '_')));
                sentOffset += wanted;
                if (sentOffset == outgoingSize) break;
            }
            sentAt = SystemClock.elapsedRealtime();
        }
    }
    private void complete(IClipboardBridge service) throws Exception {
        File root = ClipboardFileProvider.root(context);
        root.mkdirs();
        // Keep a bounded clipboard cache. Incomplete transfers are only in memory.
        File[] directories = root.listFiles();
        if (directories != null) {
            java.util.Arrays.sort(directories, java.util.Comparator.comparingLong(File::lastModified));
            for (int i = 0; i < directories.length - 9; i++) {
                File[] old = directories[i].listFiles();
                if (old != null) for (File file : old) {
                    Uri uri = uri(directories[i].getName(), file.getName());
                    context.revokeUriPermission(uri, Intent.FLAG_GRANT_READ_URI_PERMISSION); file.delete();
                }
                directories[i].delete();
            }
        }
        File directory = new File(root, UUID.randomUUID().toString());
        if (!directory.mkdir()) { cancelIncoming(); return; }
        File file = new File(directory, incomingName);
        Uri uri = uri(directory.getName(), incomingName);
        boolean success = false;
        try {
            Files.write(file.toPath(), bytes.toByteArray());
            context.grantUriPermission("com.android.shell", uri, Intent.FLAG_GRANT_READ_URI_PERMISSION);
            success = service.writeFile(uri.toString(), incomingToken);
            if (success) {
                baseline = service.readToken(); sampled = true;
                emit("clipboardFileAck", incoming, incomingSize);
            } else emit("clipboardFileCancel", incoming, 0);
        } finally {
            if (!success) { context.revokeUriPermission(uri, Intent.FLAG_GRANT_READ_URI_PERMISSION); file.delete(); directory.delete(); }
            incoming = null; bytes = null;
        }
    }
    private Uri uri(String id, String name) {
        return new Uri.Builder().scheme("content").authority(context.getPackageName() + ".clipboard.files")
            .appendPath(id).appendPath(name).build();
    }
}
