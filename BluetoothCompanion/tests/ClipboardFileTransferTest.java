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
        int advertisedSize, tokenReads;
        @Override public String readToken() { tokenReads++; return token; }
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
    private static java.util.function.Consumer<JSONObject> fileEvents(ArrayList<JSONObject> events) {
        return value -> { if (!value.optString("type").equals("clipboardFilePrepare") && !value.optString("type").equals("clipboardFilePrepareEnd")) events.add(value); };
    }
    private static JSONObject event(String type, String id, int offset) throws Exception {
        return new JSONObject().put("type", type).put("id", id).put("offset", offset);
    }
    public static void main(String[] args) throws Exception {
        Path cache = Files.createTempDirectory(Path.of("/private/tmp"), "android-clipboard-files-");
        try {
            ArrayList<JSONObject> events = new ArrayList<>();
            ClipboardFileTransfer files = new ClipboardFileTransfer(new Context(cache.toFile()), fileEvents(events));
            Bridge bridge = new Bridge();
            check(ApkInstallPolicy.allowed(5_000_001));
            check(!ApkInstallPolicy.allowed(ApkInstallPolicy.LIMIT));
            check(ApkInstallPolicy.nameAllowed("sample.APK"));
            files.poll(bridge);
            String install = UUID.randomUUID().toString();
            JSONObject beginInstall = event("clipboardFileBegin", install, 0).put("name", "sample.apk").put("size", 5_000_001).put("destination", "install").put("sha256", "a".repeat(64));
            files.receive(beginInstall, bridge);
            check(events.getLast().optString("type").equals("clipboardFileAck"));
            files.receive(event("clipboardFileChunk", install, 5_000_001).put("data", "AQID"), bridge);
            check(events.getLast().optString("type").equals("clipboardFileCancel"));
            PackageInstallClient.enabled = false;
            files.receive(beginInstall, bridge);
            check(events.getLast().optString("type").equals("clipboardFileCancel"));
            PackageInstallClient.enabled = true;
            files.receive(beginInstall.put("size", ApkInstallPolicy.LIMIT), bridge);
            check(events.getLast().optString("type").equals("clipboardFileCancel"));
            files.receive(beginInstall.put("size", 3).put("name", "sample.zip"), bridge);
            check(events.getLast().optString("type").equals("clipboardFileCancel"));
            files.receive(beginInstall.put("size", 5_000_001).put("destination", "downloads").put("name", "sample.apk"), bridge);
            check(events.getLast().optString("type").equals("clipboardFileCancel"));
            // Valid digest installs once; bytes never touch the clipboard.
            files.receive(beginInstall.put("size", 3).put("destination", "install").put("sha256", "039058c6f2c0cb492c533b0a4d14ef77cc0f78abccced5287d84a1a2011cfb81"), bridge);
            files.receive(event("clipboardFileChunk", install, 0).put("data", "AQID"), bridge);
            check(events.getLast().optString("type").equals("clipboardApkInstallResult") && events.getLast().optBoolean("ok"));
            check(java.util.Arrays.stream(cache.toFile().listFiles()).noneMatch(f -> f.getName().startsWith("apk-install-")));
            events.clear();
            // Downloads use the existing transfer checks and never write the clipboard.
            files.poll(bridge);
            String drop = UUID.randomUUID().toString();
            files.receive(event("clipboardFileBegin", drop, 0).put("name", "sample.apk").put("size", 3).put("destination", "downloads"), bridge);
            files.receive(event("clipboardFileChunk", drop, 0).put("data", "AQID"), bridge);
            check(bridge.written == null && bridge.token.equals("initial"));
            check(DownloadsFileWriter.name.equals("sample.apk") && Arrays.equals(DownloadsFileWriter.data, new byte[]{1,2,3}));
            check(events.getLast().optString("type").equals("clipboardFileAck") && events.getLast().optInt("offset") == 3);
            DownloadsFileWriter.data = null;
            drop = UUID.randomUUID().toString();
            files.receive(event("clipboardFileBegin", drop, 0).put("name", "x").put("size", 3).put("destination", "downloads"), bridge);
            files.receive(event("clipboardFileChunk", drop, 1).put("data", "AQID"), bridge);
            check(DownloadsFileWriter.data == null); // Bad offset never publishes.
            drop = UUID.randomUUID().toString();
            files.receive(event("clipboardFileBegin", drop, 0).put("name", "x").put("size", 0).put("destination", "unknown"), bridge);
            check(events.getLast().optString("type").equals("clipboardFileCancel"));
            drop = UUID.randomUUID().toString();
            files.receive(event("clipboardFileBegin", drop, 0).put("name", "x").put("size", 3).put("destination", "downloads"), bridge);
            bridge.token = "changed-during-drop";
            files.receive(event("clipboardFileChunk", drop, 0).put("data", "AQID"), bridge);
            check(DownloadsFileWriter.data == null); // Source/destination protection still applies.
            files.poll(bridge);
            DownloadsFileWriter.succeeds = false;
            drop = UUID.randomUUID().toString();
            files.receive(event("clipboardFileBegin", drop, 0).put("name", "empty").put("size", 0).put("destination", "downloads"), bridge);
            check(events.getLast().optString("type").equals("clipboardFileCancel"));
            DownloadsFileWriter.succeeds = true;
            events.clear();

            files.poll(bridge); check(events.isEmpty()); // no pre-existing upload
            bridge.source = new byte[7000];
            for (int i = 0; i < bridge.source.length; i++) bridge.source[i] = (byte) (i % 251);
            bridge.advertisedSize = bridge.source.length; bridge.token = "copied";
            files.poll(bridge);
            String id = events.getLast().getString("id");
            check(files.canReplay(id, bridge));
            String replayToken = bridge.token; bridge.token = "different source";
            check(!files.canReplay(id, bridge)); bridge.token = replayToken;
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
            // L2CAP uses 96 KiB windows while legacy GATT retains 24 KiB.
            var bulkEvents = new ArrayList<JSONObject>();
            var bulk = new ClipboardFileTransfer(new Context(cache.toFile()), fileEvents(bulkEvents), () -> 1000L, 32);
            bulk.poll(bridge);
            bridge.source = new byte[200_000]; bridge.advertisedSize = bridge.source.length; bridge.token = "bulk-window";
            bulk.poll(bridge);
            String bulkId = bulkEvents.getLast().getString("id");
            check(bulkEvents.getLast().getInt("window") == 32);
            bulkEvents.clear();
            bulk.receive(event("clipboardFileAck", bulkId, 0).put("window", 999), bridge);
            check(bulkEvents.size() == 32);
            check(bulkEvents.getLast().getInt("offset") == 31 * ClipboardFilePolicy.CHUNK);
            bulkEvents.clear();
            bridge.token = "new-copy-before-ack";
            bulk.receive(event("clipboardFileAck", bulkId, 32 * ClipboardFilePolicy.CHUNK), bridge);
            check(bulkEvents.size() == 1 && bulkEvents.getFirst().getString("type").equals("clipboardFileCancel"));
            long[] now = {1000};
            var retries = new ArrayList<JSONObject>();
            ClipboardFileTransfer replay = new ClipboardFileTransfer(new Context(cache.toFile()), fileEvents(retries), () -> now[0]);
            replay.poll(bridge);
            bridge.token = "replay-source"; replay.poll(bridge);
            String firstReplayID = retries.getLast().getString("id");
            replay.bulkFailed(); now[0] += 1001; replay.poll(bridge);
            check(!firstReplayID.equals(retries.getLast().getString("id")));
            replay.bulkFailed(); now[0] += 3001; replay.poll(bridge);
            int retryCount = retries.size();
            replay.bulkFailed(); now[0] += 10000; replay.poll(bridge);
            check(retries.size() == retryCount);
            bridge.token = "source-copy-two"; replay.poll(bridge); replay.bulkFailed();
            bridge.source = null; bridge.token = "newer-text"; now[0] += 1001; replay.poll(bridge);
            check(!retries.getLast().getString("type").equals("clipboardFileBegin"));
            bridge.source = new byte[7000]; bridge.advertisedSize = bridge.source.length;
            // 66 KiB regression: bounded windows cut application round trips to three.
            for (int window : new int[]{8, 999}) {
                bridge.source = new byte[66 * 1024];
                for (int i = 0; i < bridge.source.length; i++) bridge.source[i] = (byte) (i % 251);
                bridge.advertisedSize = bridge.source.length; bridge.token = UUID.randomUUID().toString();
                files.poll(bridge);
                id = events.getLast().getString("id");
                check(events.getLast().getInt("window") == 8);
                sent.reset();
                int batches = 0;
                while (sent.size() < bridge.source.length) {
                    int before = events.size();
                    files.receive(event("clipboardFileAck", id, sent.size()).put("window", window), bridge);
                    check(events.size() - before <= 8 && events.size() > before);
                    for (JSONObject chunk : events.subList(before, events.size())) {
                        check(chunk.getInt("offset") == sent.size());
                        sent.write(java.util.Base64.getUrlDecoder().decode(chunk.getString("data")));
                    }
                    batches++;
                }
                check(batches == 3 && Arrays.equals(sent.toByteArray(), bridge.source));
                files.receive(event("clipboardFileAck", id, sent.size()), bridge);
            }
            id = UUID.randomUUID().toString();
            files.receive(event("clipboardFileBegin", id, 0).put("name", "screenshot.bin").put("size", bridge.source.length).put("window", 8), bridge);
            check(events.getLast().getInt("window") == 8);
            int initialAcks = events.size();
            for (int offset = 0; offset < bridge.source.length; offset += ClipboardFilePolicy.CHUNK) {
                int end = Math.min(bridge.source.length, offset + ClipboardFilePolicy.CHUNK);
                files.receive(event("clipboardFileChunk", id, offset).put("data", java.util.Base64.getEncoder().encodeToString(Arrays.copyOfRange(bridge.source, offset, end))), bridge);
                check(events.size() - initialAcks == (end == bridge.source.length ? 3 : end / (8 * ClipboardFilePolicy.CHUNK)));
            }
            String screenshotPath = java.net.URI.create(bridge.written).getPath();
            check(Arrays.equals(Files.readAllBytes(cache.resolve("clipboard-files").resolve(screenshotPath.substring(1))), bridge.source));
            bridge.token = UUID.randomUUID().toString(); files.poll(bridge);
            id = events.getLast().getString("id");
            files.receive(event("clipboardFileAck", id, 0).put("window", 8), bridge);
            files.receive(event("clipboardFileAck", id, ClipboardFilePolicy.CHUNK), bridge);
            check(events.getLast().getString("type").equals("clipboardFileCancel"));
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
            // One window costs two token checks, rather than one IPC per 3 KiB chunk.
            var receiverEvents = new ArrayList<JSONObject>();
            var receiver = new ClipboardFileTransfer(new Context(cache.toFile()), fileEvents(receiverEvents), () -> 1000L, 32);
            receiver.poll(bridge);
            String receiverId = UUID.randomUUID().toString();
            receiver.receive(event("clipboardFileBegin", receiverId, 0).put("name", "bounded.bin").put("size", 33 * ClipboardFilePolicy.CHUNK).put("window", 32), bridge);
            int readsBefore = bridge.tokenReads;
            String fullChunk = java.util.Base64.getEncoder().encodeToString(new byte[ClipboardFilePolicy.CHUNK]);
            for (int i = 0; i < 32; i++) receiver.receive(event("clipboardFileChunk", receiverId, i * ClipboardFilePolicy.CHUNK).put("data", fullChunk), bridge);
            check(bridge.tokenReads - readsBefore == 2);
            // A new local clipboard mid-window must still defeat the final atomic apply.
            receiver.reset(); receiver.poll(bridge);
            receiverId = UUID.randomUUID().toString();
            receiver.receive(event("clipboardFileBegin", receiverId, 0).put("name", "stale.bin").put("size", 2 * ClipboardFilePolicy.CHUNK).put("window", 32), bridge);
            receiver.receive(event("clipboardFileChunk", receiverId, 0).put("data", fullChunk), bridge);
            String oldWritten = bridge.written;
            bridge.token = "copy-during-window";
            receiver.receive(event("clipboardFileChunk", receiverId, ClipboardFilePolicy.CHUNK).put("data", fullChunk), bridge);
            check(oldWritten.equals(bridge.written));
            check(receiverEvents.getLast().getString("type").equals("clipboardFileCancel"));
            files.poll(bridge);
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
            // Buffering a full race copy must not look idle to the existing receiver.
            long[] raceClock = {0}; ArrayList<JSONObject> raceEvents = new ArrayList<>();
            ClipboardFileTransfer buffered = new ClipboardFileTransfer(new Context(cache.toFile()), fileEvents(raceEvents), () -> raceClock[0]);
            bridge.source = null; buffered.poll(bridge);
            String bufferedId = UUID.randomUUID().toString();
            buffered.receive(event("clipboardFileBegin", bufferedId, 0).put("name", "buffered.bin").put("size", 1), bridge);
            raceClock[0] = 59000; buffered.receive(event("clipboardFileRaceProgress", bufferedId, 0), bridge);
            raceClock[0] = 61000; buffered.poll(bridge);
            buffered.receive(event("clipboardFileChunk", bufferedId, 0).put("data", "YQ=="), bridge);
            check(raceEvents.getLast().getString("type").equals("clipboardFileAck") && raceEvents.getLast().getInt("offset") == 1);
            // User cancellation cancels a pending replay and rejects late incoming data.
            long[] cancelClock = {0}; ArrayList<JSONObject> cancelEvents = new ArrayList<>();
            ClipboardFileTransfer cancelled = new ClipboardFileTransfer(new Context(cache.toFile()), fileEvents(cancelEvents), () -> cancelClock[0]);
            cancelled.poll(bridge);
            bridge.source = new byte[]{1}; bridge.advertisedSize = 1; bridge.token = "cancel-test";
            cancelled.poll(bridge);
            String cancelId = cancelEvents.getLast().getString("id");
            cancelled.bulkFailed(); cancelled.cancel(cancelId);
            int eventCount = cancelEvents.size(); cancelClock[0] = 10000; cancelled.poll(bridge);
            check(cancelEvents.size() == eventCount);
            String cancelIncomingId = UUID.randomUUID().toString();
            cancelled.receive(event("clipboardFileBegin", cancelIncomingId, 0).put("name", "cancelled.bin").put("size", 1), bridge);
            String beforeCancel = bridge.written;
            cancelled.cancel(cancelIncomingId);
            cancelled.receive(event("clipboardFileChunk", cancelIncomingId, 0).put("data", "YQ=="), bridge);
            check(java.util.Objects.equals(beforeCancel, bridge.written));
            ArrayList<JSONObject> preparingEvents = new ArrayList<>();
            ClipboardFileTransfer preparingFiles = new ClipboardFileTransfer(new Context(cache.toFile()), preparingEvents::add);
            preparingFiles.poll(bridge);
            bridge.source = new byte[]{7}; bridge.advertisedSize = 1; bridge.token = "early preparation";
            preparingFiles.poll(bridge);
            check(preparingEvents.getFirst().optString("type").equals("clipboardFilePrepare"));
            check(preparingEvents.getLast().optString("type").equals("clipboardFileBegin"));
            check(preparingEvents.getFirst().getString("id").equals(preparingEvents.getLast().getString("id")));
            System.out.println("Android file clipboard transfer tests passed");
        } finally {
            try (var paths = Files.walk(cache)) {
                for (Path path : paths.sorted(java.util.Comparator.reverseOrder()).toList()) Files.delete(path);
            }
        }
    }
}
