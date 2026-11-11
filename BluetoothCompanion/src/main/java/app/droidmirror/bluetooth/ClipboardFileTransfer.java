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
    private final int maximumWindow;
    private final Consumer<String> diagnostics;
    private long receiveStarted;
    private final Consumer<JSONObject> events;
    private final java.util.function.LongSupplier clock;
    private String baseline;
    private boolean sampled;
    private String outgoing;
    private byte[] outgoingData;
    private int outgoingSize, sentOffset;
    private String incoming, incomingName, incomingToken;
    private int incomingSize;
    private boolean incomingDownloads, incomingInstall;
    private File installFile;
    private java.io.OutputStream installOutput;
    private java.security.MessageDigest installDigest;
    private String expectedDigest;
    private int receivedBytes;
    private void cleanupInstall() {
        if (installOutput != null) try { installOutput.close(); } catch (Exception ignored) {}
        installOutput = null;
        if (installFile != null) installFile.delete();
        installFile = null;
    }
    private int incomingWindow, outgoingWindow, chunksSinceAck;
    private ByteArrayOutputStream bytes;
    private long sentAt, receivedAt;
    private String outgoingToken;
    private volatile String cancelledPreparation;
    void requestCancel(String id) { cancelledPreparation = id; }
    private int replayAttempts;
    private boolean replayPending;
    private long replayAt;

    ClipboardFileTransfer(Context context, Consumer<JSONObject> events) { this(context, events, SystemClock::elapsedRealtime); }
    ClipboardFileTransfer(Context context, Consumer<JSONObject> events, java.util.function.LongSupplier clock) {
        this(context, events, clock, ClipboardFilePolicy.WINDOW);
    }
    ClipboardFileTransfer(Context context, Consumer<JSONObject> events, java.util.function.LongSupplier clock, int maximumWindow) {
        this(context, events, clock, maximumWindow, value -> {});
    }
    ClipboardFileTransfer(Context context, Consumer<JSONObject> events, java.util.function.LongSupplier clock, int maximumWindow, Consumer<String> diagnostics) {
        this.context = context; this.events = events; this.clock = clock; this.diagnostics = diagnostics;
        this.maximumWindow = Math.max(1, Math.min(maximumWindow, 32));
    }
    private void emit(String type, String id, int offset) throws Exception {
        events.accept(new JSONObject().put("type", type).put("id", id).put("offset", offset));
    }
    private void cancelIncoming() throws Exception {
        if (incoming != null) emit("clipboardFileCancel", incoming, 0);
        incoming = null; bytes = null; cleanupInstall();
    }
    private void cancelOutgoing() throws Exception {
        if (outgoing != null) emit("clipboardFileCancel", outgoing, 0);
        outgoing = null; outgoingData = null; replayPending = false; replayAttempts = 0;
    }
    void cancel(String id) {
        if (id.equals(incoming)) { incoming = null; bytes = null; cleanupInstall(); }
        if (id.equals(outgoing)) { outgoing = null; outgoingData = null; replayPending = false; replayAttempts = 0; outgoingToken = null; }
    }
    void reset() {
        replayPending = false; replayAttempts = 0; outgoingToken = null;
        baseline = null; sampled = false; outgoing = null; outgoingData = null; incoming = null; bytes = null; cleanupInstall();
    }
    boolean canReplay(String id, IClipboardBridge service) throws Exception {
        return id.equals(outgoing) && !replayPending && outgoingToken != null && outgoingToken.equals(service.readToken());
    }
    void bulkFailed() {
        incoming = null; bytes = null; cleanupInstall();
        if (outgoing == null || replayPending) return;
        if (replayAttempts >= 2) { outgoing = null; outgoingData = null; return; }
        replayPending = true;
        replayAt = clock.getAsLong() + (replayAttempts == 0 ? 1000 : 3000);
    }
    private void begin() throws Exception {
        events.accept(new JSONObject().put("type", "clipboardFileBegin").put("id", outgoing).put("name", outgoingName)
            .put("size", outgoingSize).put("window", maximumWindow).put("sha256", digest(outgoingData)));
    }
    private static String digest(byte[] bytes) throws Exception {
        StringBuilder hex = new StringBuilder();
        for (byte b : java.security.MessageDigest.getInstance("SHA-256").digest(bytes)) hex.append(String.format(java.util.Locale.ROOT, "%02x", b & 255));
        return hex.toString();
    }
    private String outgoingName;
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
        long now = clock.getAsLong();
        if (outgoing != null && now - sentAt > 60_000) cancelOutgoing();
        if (incoming != null && now - receivedAt > 60_000) cancelIncoming();
        String token = service.readToken();
        if (token == null) { reset(); return; }
        boolean changed = sampled && !token.equals(baseline);
        sampled = true; baseline = token;
        if (!changed) {
            if (replayPending && now >= replayAt) {
                if (outgoing != null && token.equals(outgoingToken)) {
                    outgoing = UUID.randomUUID().toString().toUpperCase(java.util.Locale.ROOT);
                    sentOffset = 0; sentAt = now; replayPending = false; replayAttempts++;
                    begin();
                } else { outgoing = null; outgoingData = null; replayPending = false; }
            }
            return;
        }
        cancelIncoming(); cancelOutgoing();
        String info = service.readFileInfo();
        if (info == null) return;
        JSONObject file = new JSONObject(info);
        int size = file.getInt("size"); String name = file.getString("name");
        if (!ClipboardFilePolicy.allowed(size) || !ClipboardFilePolicy.nameAllowed(name)) return;
        String candidate = UUID.randomUUID().toString().toUpperCase(java.util.Locale.ROOT);
        events.accept(new JSONObject().put("type", "clipboardFilePrepare").put("id", candidate));
        boolean begun = false;
        try {
            // The UI is already visible while the bounded source snapshot is read.
            ByteArrayOutputStream snapshot = new ByteArrayOutputStream();
            while (true) {
                if (candidate.equals(cancelledPreparation) || !token.equals(service.readToken())) return;
                byte[] part = service.readFileChunk(file.getString("uri"), snapshot.size());
                if (part == null || part.length > ClipboardFilePolicy.CHUNK || snapshot.size() + part.length > size) return;
                if (part.length == 0) break;
                snapshot.write(part);
            }
            if (snapshot.size() != size || candidate.equals(cancelledPreparation)) return;
            outgoing = candidate; outgoingData = snapshot.toByteArray();
            outgoingSize = size; outgoingName = name; outgoingToken = token; replayAttempts = 0; replayPending = false; sentOffset = 0; sentAt = now;
            begin(); begun = true;
        } finally {
            if (!begun) events.accept(new JSONObject().put("type", "clipboardFilePrepareEnd").put("id", candidate));
        }
    }
    void receive(JSONObject event, IClipboardBridge service) throws Exception {
        String type = event.optString("type"), id = event.optString("id");
        if (!id.matches("[a-fA-F0-9-]{36}")) return;
        if (type.equals("clipboardFileRaceProgress")) {
            if (id.equals(incoming)) receivedAt = clock.getAsLong();
            return;
        }
        if (type.equals("clipboardFileCancel")) {
            if (id.equals(incoming)) { incoming = null; bytes = null; cleanupInstall(); }
            if (id.equals(outgoing)) { outgoing = null; outgoingData = null; replayPending = false; }
        } else if (type.equals("clipboardFileBegin")) {
            cancelIncoming();
            long size = event.optLong("size", -1); String name = event.optString("name");
            String destination = event.optString("destination", "clipboard");
            if (!destination.equals("clipboard") && !destination.equals("downloads") && !destination.equals("install")) {
                emit("clipboardFileCancel", id, 0); return;
            }
            incomingInstall = destination.equals("install");
            incomingDownloads = destination.equals("downloads");
            String token = service.readToken();
            if (!(incomingInstall ? ApkInstallPolicy.allowed(size) && ApkInstallPolicy.nameAllowed(name) && PackageInstallClient.available() : ClipboardFilePolicy.allowed(size) && ClipboardFilePolicy.nameAllowed(name))
                    || token == null || !sampled || !token.equals(baseline)) {
                emit("clipboardFileCancel", id, 0); return;
            }
            cancelOutgoing();
            incoming = id; incomingName = name; incomingSize = (int) size; incomingToken = token;
            incomingWindow = Math.max(1, Math.min(event.optInt("window", 1), maximumWindow));
            chunksSinceAck = 0;
            receivedBytes = 0;
            if (incomingInstall) {
                expectedDigest = event.optString("sha256");
                if (!expectedDigest.matches("[a-f0-9]{64}")) { cancelIncoming(); return; }
                installDigest = java.security.MessageDigest.getInstance("SHA-256");
                installFile = File.createTempFile("apk-install-", ".apk", context.getCacheDir());
                installOutput = new java.io.FileOutputStream(installFile);
            } else bytes = new ByteArrayOutputStream(incomingSize);
            receivedAt = clock.getAsLong(); receiveStarted = receivedAt;
            diagnostics.accept("Receive begin bytes=" + incomingSize + " window=" + incomingWindow);
            if (size == 0) complete(service);
            else events.accept(new JSONObject().put("type", "clipboardFileAck").put("id", id).put("offset", 0).put("window", incomingWindow));
        } else if (type.equals("clipboardFileChunk") && id.equals(incoming)) {
            // Bound expensive cross-process clipboard checks to negotiated window boundaries.
            // Completion still uses writeFile(expectedToken), which checks again atomically.
            if ((chunksSinceAck == 0 && !incomingToken.equals(service.readToken())) || event.optInt("offset", -1) != receivedBytes) {
                cancelIncoming(); return;
            }
            String encoded = event.optString("data");
            if (encoded.length() > 4096) { cancelIncoming(); return; }
            byte[] chunk;
            try { chunk = Base64.decode(encoded.replace('-', '+').replace('_', '/'), Base64.NO_WRAP); }
            catch (IllegalArgumentException failure) { cancelIncoming(); return; }
            if (chunk.length == 0 || chunk.length > ClipboardFilePolicy.CHUNK || receivedBytes + chunk.length > incomingSize) {
                cancelIncoming(); return;
            }
            if (incomingInstall) { installOutput.write(chunk); installDigest.update(chunk); }
            else bytes.write(chunk);
            receivedBytes += chunk.length; receivedAt = clock.getAsLong();
            chunksSinceAck++;
            if (receivedBytes == incomingSize) complete(service);
            else if (chunksSinceAck == incomingWindow) {
                if (!incomingToken.equals(service.readToken())) { cancelIncoming(); return; }
                chunksSinceAck = 0;
                diagnostics.accept("Receive progress bytes=" + receivedBytes + " elapsedMs=" + (clock.getAsLong() - receiveStarted));
                emit("clipboardFileAck", id, receivedBytes);
            }
        } else if (type.equals("clipboardFileAck") && id.equals(outgoing)) {
            if (event.optInt("offset", -1) != sentOffset || !baseline.equals(service.readToken())) {
                cancelOutgoing(); return;
            }
            if (sentOffset == outgoingSize) {
                outgoing = null; outgoingData = null; replayPending = false; replayAttempts = 0; return;
            }
            if (sentOffset == 0) outgoingWindow = Math.max(1, Math.min(event.optInt("window", 1), maximumWindow));
            for (int i = 0; i < outgoingWindow; i++) {
                int wanted = Math.min(ClipboardFilePolicy.CHUNK, outgoingSize - sentOffset);
                byte[] chunk = java.util.Arrays.copyOfRange(outgoingData, sentOffset, sentOffset + wanted);
                events.accept(new JSONObject().put("type", "clipboardFileChunk").put("id", id).put("offset", sentOffset)
                    .put("data", Base64.encodeToString(chunk, Base64.NO_WRAP).replace('+', '-').replace('/', '_')));
                sentOffset += wanted;
                if (sentOffset == outgoingSize) break;
            }
            sentAt = clock.getAsLong();
        }
    }
    private void complete(IClipboardBridge service) throws Exception {
        if (incomingInstall) {
            String id = incoming, packageName = "", message = "APK installation failed";
            boolean ok = false;
            try {
                installOutput.close(); installOutput = null;
                StringBuilder hash = new StringBuilder();
                for (byte b : installDigest.digest()) hash.append(String.format(java.util.Locale.ROOT, "%02x", b & 255));
                if (!expectedDigest.equals(hash.toString())) message = "APK digest mismatch";
                else if (!incomingToken.equals(service.readToken()) || id.equals(cancelledPreparation)) message = "APK transfer cancelled";
                else {
                    packageName = PackageInstallClient.packageName(context, installFile);
                    if (packageName == null) { packageName = ""; message = "Cannot parse APK archive"; }
                    else if (context.getPackageName().equals(packageName)) message = "Update the DroidMirror companion via the normal update path; installing it during mirroring would end the session";
                    else {
                        emit("clipboardFileAck", id, incomingSize);
                        message = PackageInstallClient.install(context, installFile, incomingSize, () -> id.equals(cancelledPreparation) || "*".equals(cancelledPreparation));
                        ok = message.contains("Success");
                    }
                }
                events.accept(new JSONObject().put("type", "clipboardApkInstallResult").put("id", id).put("ok", ok).put("message", message).put("package", packageName));
            } finally { incoming = null; bytes = null; cleanupInstall(); }
            return;
        }
        if (incomingDownloads) {
            boolean success = incomingToken.equals(service.readToken())
                && DownloadsFileWriter.save(context, incomingName, bytes.toByteArray());
            emit(success ? "clipboardFileAck" : "clipboardFileCancel", incoming, success ? incomingSize : 0);
            incoming = null; bytes = null; cleanupInstall();
            return;
        }
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
            diagnostics.accept("Receive complete bytes=" + incomingSize + " elapsedMs=" + (clock.getAsLong() - receiveStarted) + " applied=" + success);
            if (success) {
                baseline = service.readToken(); sampled = true;
                emit("clipboardFileAck", incoming, incomingSize);
            } else emit("clipboardFileCancel", incoming, 0);
        } finally {
            if (!success) { context.revokeUriPermission(uri, Intent.FLAG_GRANT_READ_URI_PERMISSION); file.delete(); directory.delete(); }
            incoming = null; bytes = null; cleanupInstall();
        }
    }
    private Uri uri(String id, String name) {
        return new Uri.Builder().scheme("content").authority(context.getPackageName() + ".clipboard.files")
            .appendPath(id).appendPath(name).build();
    }
}
