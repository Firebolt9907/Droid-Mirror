package app.droidmirror.bluetooth;

import android.net.LocalServerSocket;
import android.net.LocalSocket;
import java.io.*;
import java.security.MessageDigest;
import java.security.SecureRandom;

/** Active-session-only local endpoint reached through the paired Iroh tunnel. */
final class WirelessVideoUpgrade implements AutoCloseable {
    private final LocalServerSocket listener;
    private final Thread worker;
    private volatile LocalSocket candidate;
    private volatile boolean closed;
    private volatile byte[] activeNonce;
    private final BluetoothWire wire;
    private final QualityUpgrade quality;
    interface AudioSession {
        void poll() throws IOException;
        void start() throws IOException;
        void stop();
    }
    private final AudioSession audio;
    private final Object transition=new Object();
    private final java.util.concurrent.CountDownLatch captureStarted = new java.util.concurrent.CountDownLatch(1);
    void captureReady() { captureStarted.countDown(); }
    private final java.util.concurrent.atomic.AtomicBoolean recovering=new java.util.concurrent.atomic.AtomicBoolean();
    // A null profile restores the original Bluetooth encoder settings.
    interface QualityUpgrade { void apply(WirelessVideoProfile profile) throws IOException; }

    WirelessVideoUpgrade(BluetoothWire wire, byte[] key, QualityUpgrade quality) throws IOException {
        this(wire, key, quality, false);
    }

    WirelessVideoUpgrade(BluetoothWire wire, byte[] key, QualityUpgrade quality, boolean allowInitial) throws IOException {
        this(wire, key, quality, allowInitial, null);
    }

    WirelessVideoUpgrade(BluetoothWire wire, byte[] key, QualityUpgrade quality, boolean allowInitial, AudioSession audio) throws IOException {
        this.wire=wire; this.quality=quality; this.audio=audio;
        if (!allowInitial) captureReady();
        listener = new LocalServerSocket("droidmirror_video_upgrade");
        worker = new Thread(() -> {
            try {
                while (!closed) {
                    LocalSocket socket = listener.accept();
                    System.err.println("DroidMirror video candidate accepted");
                    candidate = socket;
                    if (closed) { socket.close(); break; }
                    boolean committed = false;
                    BluetoothWire.Preview preview = null;
                    java.util.concurrent.CountDownLatch warmupDone = new java.util.concurrent.CountDownLatch(1);
                    try {
                        socket.setSoTimeout(2000);
                        DataInputStream input = new DataInputStream(socket.getInputStream());
                        OutputStream output = socket.getOutputStream();
                        byte[] nonce = new byte[32]; new SecureRandom().nextBytes(nonce);
                        output.write((allowInitial ? "DMWIFI06" : "DMWIFI05").getBytes(java.nio.charset.StandardCharsets.US_ASCII));
                        output.write(nonce); output.flush();
                        byte[] requested = new byte[WirelessVideoProfile.WIRE_SIZE]; input.readFully(requested);
                        byte[] proof = new byte[32]; input.readFully(proof);
                        if (!MessageDigest.isEqual(proof, WirelessUpgradeAuth.proof(key, "client", nonce, requested))) continue;
                        WirelessVideoProfile profile = WirelessVideoProfile.parse(requested);
                        Thread deadline=new Thread(() -> {
                            try {
                                if (!warmupDone.await(10,java.util.concurrent.TimeUnit.SECONDS)) abort(socket);
                            } catch (InterruptedException interrupted) { Thread.currentThread().interrupt(); }
                        },"WirelessWarmupDeadline");
                        deadline.setDaemon(true); deadline.start();
                        if (!allowInitial) preview=wire.beginPreview();
                        output.write(WirelessUpgradeAuth.proof(key, "preview server", nonce, requested));
                        output.flush();
                        if (allowInitial) {
                            committed=wire.upgradeInitial(output,key,nonce,requested);
                            if (committed) activeNonce=nonce;
                        }
                        if (!committed) {
                            if (preview==null) preview=wire.beginPreview();
                            // Authenticate the warm-up separately from the eventual cutoff.
                            // Socket writes happen on this worker, never the Classic writer.
                            DataOutputStream warmup=new DataOutputStream(output);
                            long until=System.nanoTime()+8_000_000_000L;
                            long lastWarmup=System.nanoTime();
                            while (input.available()==0) {
                                if (closed || System.nanoTime()>=until) throw new IOException("Wireless video warm-up timed out");
                                BluetoothWire.Preview.Record record=preview.poll();
                                if (record!=null) {
                                    if (record.bytes==null) { warmup.writeInt(-2); warmup.writeLong(record.timestamp); }
                                    else { warmup.writeInt(record.bytes.length); warmup.write(record.bytes); }
                                    warmup.flush();
                                    lastWarmup=System.nanoTime();
                                } else if (System.nanoTime()-lastWarmup>=100_000_000L) {
                                    // Recheck delivery even while capture is idle. These
                                    // copies stay on the candidate and never reach the decoder.
                                    long sample=System.nanoTime();
                                    byte[] frame=wire.previewFrame();
                                    if(frame!=null) {
                                        wire.previewLatencySample(sample);
                                        for(int offset=0;offset<frame.length;) {
                                            int length=Math.min(8192,frame.length-offset);
                                            warmup.writeInt(length); warmup.write(frame,offset,length); offset+=length;
                                        }
                                        warmup.writeInt(-2); warmup.writeLong(sample);
                                        warmup.writeInt(0); warmup.flush();
                                    }
                                    lastWarmup=System.nanoTime();
                                }
                            }
                            if (input.readUnsignedByte()!=1) throw new IOException("Wireless warm-up rejected");
                            wire.endPreview(preview); preview=null;
                            warmup.writeInt(-1); warmup.flush();
                            activeNonce=nonce;
                            committed = wire.upgrade(output, key, nonce, requested);
                        }
                        warmupDone.countDown();
                        if (committed) {
                            // The receiver must drain the old Classic cutoff first.
                            // Only then may larger frames and bitrate enter Wi-Fi.
                            socket.setSoTimeout(8000);
                            if (input.readUnsignedByte() != 1) throw new IOException("Wi-Fi receiver did not confirm handoff");
                            synchronized (transition) {
                                if (recovering.get() || !wire.isWireless()) throw new IOException("Wi-Fi handoff was cancelled");
                                wire.enableWirelessThroughput();
                                // Capture and BLE authentication continue independently.
                                // Never wait for a LAN candidate on the capture thread.
                                try {
                                    if (!captureStarted.await(15,java.util.concurrent.TimeUnit.SECONDS))
                                        throw new IOException("Capture did not start");
                                } catch (InterruptedException interrupted) {
                                    Thread.currentThread().interrupt(); throw new IOException(interrupted);
                                }
                                if (closed || recovering.get() || !wire.isWireless()) throw new IOException("Session ended during startup");
                                quality.apply(profile);
                            }
                            // Bluetooth stays idle until the Mac requests recovery over BLE.
                            boolean audioNegotiated = false;
                            long heartbeat = 0;
                            while (!closed && wire.isWireless()) {
                                // The reverse direction belongs to this authenticated
                                // candidate. Old receivers never opt into new records.
                                while (input.available() > 0) {
                                    int command = input.readUnsignedByte();
                                    if (command == 4) audioNegotiated = true;
                                    else if (audioNegotiated && audio != null && command == 2) audio.start();
                                    else if (audioNegotiated && audio != null && command == 3) audio.stop();
                                    else throw new IOException("Invalid audio command");
                                }
                                if (audioNegotiated && audio != null) audio.poll();
                                if (System.nanoTime() - heartbeat >= 1_000_000_000L) {
                                    wire.wirelessHeartbeat(); heartbeat = System.nanoTime();
                                }
                                try { Thread.sleep(250); }
                                catch (InterruptedException interrupted) { Thread.currentThread().interrupt(); return; }
                            }
                        }
                    } catch (IOException unavailable) {
                        if (!closed) System.err.println("DroidMirror video candidate " + (committed ? "disconnected: " : "not ready: ") + unavailable.getMessage());
                        // Probes are harmless before commit. After commit, the
                        // Mac restarts Classic video through the authenticated BLE path.
                        if (committed) abort(socket);
                    } finally {
                        warmupDone.countDown();
                        if (audio != null) audio.stop();
                        if (preview!=null) wire.endPreview(preview);
                        abort(socket);
                        if (candidate==socket) candidate=null;
                    }
                    // A lost ADB transport must not accept another upgrade until
                    // the BLE-requested Bluetooth recovery has finished.
                    while (!closed && wire.isWireless()) {
                        try { Thread.sleep(50); }
                        catch (InterruptedException interrupted) { Thread.currentThread().interrupt(); return; }
                    }
                }
            } catch (IOException stopped) {
                // Closing the session interrupts accept/read/write.
            } finally { try { listener.close(); } catch (IOException ignored) {} }
        }, "WirelessVideoUpgrade");
        worker.start();
    }

    void fallback(byte[] nonce, long received) {
        byte[] active=activeNonce;
        if (closed || active==null || !MessageDigest.isEqual(active,nonce) || !wire.isWireless() || !recovering.compareAndSet(false,true)) return;
        // Do not wait for the wire monitor: its writer may be blocked in ADB.
        LocalSocket socket=candidate;
        abort(socket);
        if (audio != null) audio.stop();
        new Thread(() -> {
            try {
                synchronized (transition) {
                    quality.apply(null);
                    wire.fallback(received);
                    System.err.println("DroidMirror Bluetooth video recovery completed");
                }
            } catch (IOException failed) { close(); }
            finally { recovering.set(false); }
        },"BluetoothVideoFallback").start();
    }

    private static void abort(LocalSocket socket) {
        if (socket==null) return;
        // close() alone need not interrupt a native write already using the fd.
        // shutdown releases that write before fallback needs the wire monitor.
        try { socket.shutdownOutput(); } catch (IOException ignored) {}
        try { socket.shutdownInput(); } catch (IOException ignored) {}
        try { socket.close(); } catch (IOException ignored) {}
    }

    @Override public void close() {
        closed = true;
        captureReady();
        // close(fd) does not cancel another thread's blocking accept on Android.
        // That syscall can retain the abstract name and break every later session.
        try { android.system.Os.shutdown(listener.getFileDescriptor(), android.system.OsConstants.SHUT_RDWR); }
        catch (android.system.ErrnoException ignored) { }
        try { listener.close(); } catch (IOException ignored) {}
        abort(candidate);
        if (audio != null) audio.stop();
        if (Thread.currentThread()!=worker) {
            try { worker.join(250); }
            catch (InterruptedException interrupted) { Thread.currentThread().interrupt(); }
        }
    }
}
