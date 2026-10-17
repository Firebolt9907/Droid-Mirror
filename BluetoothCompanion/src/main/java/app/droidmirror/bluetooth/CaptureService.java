package app.droidmirror.bluetooth;

import app.droidmirror.bluetooth.bridge.BridgeRuntime;
import android.Manifest;
import android.app.*;
import android.bluetooth.*;
import android.content.*;
import android.content.pm.PackageManager;
import android.content.pm.ServiceInfo;
import android.os.*;
import java.io.*;
import java.util.UUID;
import java.util.concurrent.*;
import java.util.concurrent.atomic.*;

/** Persistent, paired-Mac listener. Capture begins when the Mac connects, never from a phone share prompt. */
public final class CaptureService extends Service {
    private volatile boolean shutdown;
    private volatile BridgeRuntime bridge;
    private volatile String captureStatus = "Select a paired Mac to enable mirroring";
    private volatile ClassicL2capClient listener;
    private volatile String listenerPeer;
    private volatile ParcelFileDescriptor socket;
    private static final class SessionState {
        final String token = UUID.randomUUID().toString();
        String peerName;
        volatile long startedElapsed;
        volatile boolean promotionDismissed;
        volatile ParcelFileDescriptor inputPipe;
        volatile ParcelFileDescriptor controlPipe;
        volatile BluetoothWire wire;
        volatile WirelessVideoUpgrade wirelessUpgrade;
        volatile PeerVideoTransport peerTransport;
        volatile BleInputServer ble;
        volatile ShizukuDisplayClient guard;
        volatile boolean stopped;
        volatile boolean hasGuard;
        volatile long lastPeerSeen;
        final VideoWindow videoWindow = VideoWindow.bluetooth(5000);
        final AtomicInteger endEvent = new AtomicInteger();
        final AtomicBoolean streamStarted = new AtomicBoolean();
        final AtomicBoolean auditPosted = new AtomicBoolean();
        final AtomicBoolean heartbeatReply = new AtomicBoolean();
        final CountDownLatch eventReady = new CountDownLatch(1);
    }
    private volatile SessionState current;
    private final BroadcastReceiver screenActions = new BroadcastReceiver() {
        @Override public void onReceive(Context context, Intent intent) {
            SessionState state = current;
            if (Intent.ACTION_SCREEN_OFF.equals(intent.getAction()) && state != null && !state.stopped
                && state.endEvent.get() == 0 && state.guard != null)
                state.guard.localUse();
        }
    };
    @Override public void onCreate() {
        super.onCreate();
        IntentFilter filter = new IntentFilter(Intent.ACTION_SCREEN_OFF);
        if (Build.VERSION.SDK_INT >= 33) registerReceiver(screenActions, filter, Context.RECEIVER_NOT_EXPORTED);
        else registerReceiver(screenActions, filter);
    }
    private Thread server;
    private ScheduledExecutorService watchdog;
    private final Object notificationLock = new Object();

    public enum ReadyResult { START_REQUESTED, NOT_CONFIGURED, PERMISSION_REQUIRED, BACKGROUND_RESTRICTED, FAILED }

    public static ReadyResult enableIfConfigured(Context context) {
        android.content.SharedPreferences settings = context.getSharedPreferences("ready", MODE_PRIVATE);
        if (!BackgroundBridgePreferences.enabled(context)) return ReadyResult.NOT_CONFIGURED;
        if (Build.VERSION.SDK_INT >= 31 && (context.checkSelfPermission(Manifest.permission.BLUETOOTH_CONNECT) != PackageManager.PERMISSION_GRANTED
                || context.checkSelfPermission(Manifest.permission.BLUETOOTH_ADVERTISE) != PackageManager.PERMISSION_GRANTED)) return ReadyResult.PERMISSION_REQUIRED;
        try {
            byte[] pairing = settings.getString("peer", "").isEmpty() ? new byte[0]
                : BlePairing.key(context, settings.getString("peer", ""));
            java.util.Arrays.fill(pairing, (byte)0);
        } catch (IOException error) {
            android.util.Log.w("DroidMirrorReady", "Could not initialize BLE pairing", error);
            return ReadyResult.FAILED;
        }
        try {
            context.startForegroundService(new Intent(context, CaptureService.class));
            return ReadyResult.START_REQUESTED;
        } catch (SecurityException error) {
            android.util.Log.w("DroidMirrorReady", "Readiness requires existing permissions", error);
            return ReadyResult.PERMISSION_REQUIRED;
        } catch (RuntimeException error) {
            android.util.Log.w("DroidMirrorReady", "Android refused readiness startup", error);
            if (Build.VERSION.SDK_INT >= 31 && error instanceof ForegroundServiceStartNotAllowedException)
                return ReadyResult.BACKGROUND_RESTRICTED;
            return ReadyResult.FAILED;
        }
    }
    @Override public IBinder onBind(Intent intent) { return null; }
    private Notification notification(String text) {
        SessionState state = current;
        if (state != null && state.streamStarted.get() && !state.stopped)
            return StreamNotifications.streaming(this, state.token, state.peerName, state.startedElapsed, state.promotionDismissed);
        PendingIntent open = PendingIntent.getActivity(this, 0, new Intent(this, CaptureActivity.class), PendingIntent.FLAG_IMMUTABLE);
        BridgeRuntime runtime = bridge;
        return new Notification.Builder(this, "capture").setSmallIcon(android.R.drawable.ic_menu_camera)
            .setContentTitle("DroidMirror background bridge")
            .setContentText(text + (runtime == null ? "" : " · " + runtime.getStatus())).setContentIntent(open)
            .setOngoing(true).setOnlyAlertOnce(true).build();
    }
    private void status(String text) {
        android.util.Log.i("DroidMirrorStatus", text);
        captureStatus = text;
        refreshNotification();
    }
    private void refreshNotification() {
        synchronized (notificationLock) {
            if (!shutdown) getSystemService(NotificationManager.class).notify(1, notification(captureStatus));
        }
    }
    @Override public int onStartCommand(Intent intent, int flags, int id) {
        if (intent != null && (StreamNotifications.DISCONNECT.equals(intent.getAction())
                || StreamNotifications.DISMISSED.equals(intent.getAction())
                || StreamNotifications.MINIMIZE.equals(intent.getAction()))) {
            notificationAction(intent);
            // A stale PendingIntent must not start readiness after a process death.
            if (bridge == null && server == null) { stopSelfResult(id); return START_NOT_STICKY; }
            return START_STICKY;
        }
        if (!BackgroundBridgePreferences.enabled(this)) { stopSelf(); return START_NOT_STICKY; }
        if (Build.VERSION.SDK_INT >= 31 && (checkSelfPermission(Manifest.permission.BLUETOOTH_CONNECT) != PackageManager.PERMISSION_GRANTED
                || checkSelfPermission(Manifest.permission.BLUETOOTH_ADVERTISE) != PackageManager.PERMISSION_GRANTED)) {
            stopSelf(); return START_NOT_STICKY;
        }
        NotificationManager notifications = getSystemService(NotificationManager.class);
        notifications.createNotificationChannel(new NotificationChannel("capture", "DroidMirror background bridge", NotificationManager.IMPORTANCE_LOW));
        synchronized (notificationLock) {
            if (Build.VERSION.SDK_INT >= 29) startForeground(1, notification(captureStatus), ServiceInfo.FOREGROUND_SERVICE_TYPE_CONNECTED_DEVICE);
            else startForeground(1, notification(captureStatus));
        }
        if (bridge == null) {
            bridge = new BridgeRuntime(this, this::refreshNotification);
            try { bridge.start(); }
            catch (RuntimeException error) {
                bridge.close(); bridge = null;
                android.util.Log.w("DroidMirrorBluetooth", "Discovery could not start", error);
            }
        }
        // Discovery and notification forwarding work before a capture Mac is selected.
        if (getSharedPreferences("ready", MODE_PRIVATE).getString("peer", "").isEmpty()) return START_STICKY;
        if (server != null) {
            if (listener != null && !getSharedPreferences("ready", MODE_PRIVATE).getString("peer", "").equals(listenerPeer)) listener.close();
            return START_STICKY;
        }
        watchdog = Executors.newSingleThreadScheduledExecutor();
        watchdog.scheduleWithFixedDelay(() -> {
            SessionState state = current;
            if (state != null && !state.stopped && state.wire != null
                    && state.wire.writeStalled(SystemClock.elapsedRealtime() - state.lastPeerSeen)) {
                synchronized (CaptureService.this) {
                    if (current == state && !state.stopped
                            && state.wire.writeStalled(SystemClock.elapsedRealtime() - state.lastPeerSeen)) {
                        android.util.Log.w("DroidMirrorBluetooth", "Bluetooth write and peer heartbeat stalled for five seconds");
                        stopSession();
                    }
                }
            }
        }, 100, 100, TimeUnit.MILLISECONDS);
        server = new Thread(this::listen, "BluetoothReady"); server.start();
        return START_STICKY;
    }
    private synchronized void notificationAction(Intent intent) {
        SessionState state = current;
        if (state == null || state.stopped || !state.streamStarted.get()
                || !state.token.equals(intent.getStringExtra(StreamNotifications.TOKEN))) return;
        if (StreamNotifications.MINIMIZE.equals(intent.getAction())) {
            // The capture BLE channel is already authenticated to this session's
            // Mac; background discovery may be unavailable while it is active.
            new Thread(() -> {
                try {
                    BluetoothWire wire = state.wire;
                    if (current == state && !state.stopped && wire != null) wire.event(BluetoothWire.MINIMIZE_WINDOW);
                } catch (IOException error) {
                    android.util.Log.w("DroidMirrorBluetooth", "Could not send minimize command", error);
                }
            }, "MinimizeMirror").start();
            return;
        }
        if (StreamNotifications.DISMISSED.equals(intent.getAction())) {
            state.promotionDismissed = true;
            return;
        }
        if (!state.endEvent.compareAndSet(0, BluetoothWire.SESSION_ENDED)) return;
        // Ordinary release restores the panel. Never route notification actions through localUse().
        ShizukuDisplayClient guard = state.guard;
        if (guard != null) guard.close();
        // Normally capture EOF drains SESSION_ENDED; bound shutdown even if an encoder fails to close.
        if (watchdog != null) watchdog.schedule(() -> {
            synchronized (CaptureService.this) {
                if (current == state && !state.stopped) { stopSession(); status("Ready for your paired Mac"); }
            }
        }, 750, TimeUnit.MILLISECONDS);
    }
    private void listen() {
        while (!shutdown) {
            try {
                if (Build.VERSION.SDK_INT >= 31 && checkSelfPermission(Manifest.permission.BLUETOOTH_CONNECT) != PackageManager.PERMISSION_GRANTED) throw new SecurityException();
                BluetoothAdapter adapter = getSystemService(BluetoothManager.class).getAdapter();
                if (adapter == null || !adapter.isEnabled()) { status("Enable Bluetooth to connect your Mac"); Thread.sleep(2000); continue; }
                if (!ShizukuDisplayClient.authorized()) { status("Authorize Shizuku to enable Classic L2CAP"); Thread.sleep(2000); continue; }
                if (listener == null) {
                    listener = new ClassicL2capClient(this);
                    listenerPeer=getSharedPreferences("ready", MODE_PRIVATE).getString("peer", "");
                    listener.listen(listenerPeer);
                    status("Ready for your paired Mac · Classic L2CAP");
                }
                // Shell enforces authentication, bonding and the selected Mac before
                // passing this video-only write descriptor. The fixed PSM remains stable.
                socket = listener.accept();
                if (!getSharedPreferences("ready", MODE_PRIVATE).getString("peer", "").equals(listenerPeer)) throw new IOException("Selected Mac changed");
                serve();
            } catch (Exception error) {
                if (listener != null) listener.close();
                listener = null;
                if (!shutdown) {
                    android.util.Log.w("DroidMirrorBluetooth", "Bluetooth listener failed", error);
                    status("Waiting for Bluetooth and Shizuku");
                    try { Thread.sleep(1000); } catch (InterruptedException ignored) {}
                }
            } finally {
                stopSession();
            }
        }
    }
    private void serve() {
        SessionState state = new SessionState(); current = state;
        BluetoothWire wire = null;
        try {
            if (Build.VERSION.SDK_INT >= 31 && checkSelfPermission(Manifest.permission.BLUETOOTH_CONNECT) != PackageManager.PERMISSION_GRANTED)
                throw new SecurityException("Nearby Devices permission was revoked");
            String peer = getSharedPreferences("ready", MODE_PRIVATE).getString("peer", "");
            String name = getSystemService(BluetoothManager.class).getAdapter().getRemoteDevice(peer).getName();
            state.peerName = name == null || name.trim().isEmpty() ? getString(R.string.stream_peer_fallback) : name;
            wire = new BluetoothWire(new FileOutputStream(socket.getFileDescriptor()), SystemClock::elapsedRealtime, BluetoothWire.videoChunkForMtu(listener.transmitMtu())); state.wire = wire;
            // Bound data queued ahead of the receiver; socket writes can otherwise
            // enqueue seconds of old video even though the radio is reliable.
            wire.setVideoWindow(state.videoWindow);
            if (!ShizukuDisplayClient.authorized()) { wire.event(BluetoothWire.CAPTURE_FAILED); status("Authorize Shizuku on the phone once to enable Mac-initiated capture"); return; }
            state.hasGuard = true;
            state.guard = new ShizukuDisplayClient(this, getSharedPreferences("ready", MODE_PRIVATE).getBoolean("panelOff", true), this::status,
                (cause, awake) -> {
                    if (!state.stopped) {
                        state.endEvent.compareAndSet(0, cause == RemoteSession.LOCAL_USE
                            ? (awake ? BluetoothWire.PHONE_ON : BluetoothWire.LOCAL_USE_FAILED) : BluetoothWire.SESSION_ENDED);
                        state.eventReady.countDown();
                    }
                }, posted -> auditEnd(state, posted));
            ParcelFileDescriptor[] pipe = ParcelFileDescriptor.createPipe(); state.inputPipe = pipe[0];
            ParcelFileDescriptor[] controls = ParcelFileDescriptor.createSocketPair(); state.controlPipe = controls[0];
            try (ParcelFileDescriptor output = pipe[1]; ParcelFileDescriptor remoteControls = controls[1]) {
                byte[] key=new byte[32]; new java.security.SecureRandom().nextBytes(key);
                state.ble=new BleInputServer(this,key,peer,() -> {
                    synchronized(CaptureService.this) { if(current==state) stopSession(); }
                });
                state.ble.start(); wire.setSideChannel(state.ble::send); java.util.Arrays.fill(key,(byte)0);
                startControls(state,state.ble.input(),wire);
                status("Waiting for authenticated BLE input");
                if (!state.ble.awaitInput()) throw new IOException("BLE input connection timed out");
                try {
                    synchronized (CaptureService.this) {
                        if (!state.stopped) state.wirelessUpgrade = new WirelessVideoUpgrade(state.wire, BlePairing.key(this, peer), profile -> {
                            ShizukuDisplayClient guard = state.guard;
                            if (state.stopped || guard == null) throw new IOException("Video session ended before quality upgrade");
                            if (profile==null) guard.restoreBluetoothVideo(); else guard.upgradeVideo(profile);
                        });
                        if (!state.stopped) state.peerTransport = new PeerVideoTransport(this, BlePairing.key(this, peer));
                    }
                }
                catch (IOException unavailable) { android.util.Log.d("DroidMirrorBluetooth", "Wireless upgrade unavailable", unavailable); }
                state.guard.startVideo(output, remoteControls);
            }
            ByteArrayOutputStream header = new ByteArrayOutputStream();
            VideoWire.deviceHeader(new DataOutputStream(header), Build.MODEL);
            sendVideo(wire, header.toByteArray());
            try (DataInputStream input = new DataInputStream(new ParcelFileDescriptor.AutoCloseInputStream(state.inputPipe))) {
                byte[] codec = new byte[4]; input.readFully(codec); sendVideo(wire, codec);
                long statsStarted = SystemClock.elapsedRealtime(), frames = 0, bytesSent = 0, sendingMillis = 0;
                while (!shutdown && !state.stopped && state.endEvent.get() == 0) {
                    byte[] frameHeader = new byte[12]; input.readFully(frameHeader);
                    if ((frameHeader[0] & 0x80) != 0) { sendVideo(wire, frameHeader); continue; }
                    int size = ((frameHeader[8] & 255) << 24) | ((frameHeader[9] & 255) << 16) | ((frameHeader[10] & 255) << 8) | (frameHeader[11] & 255);
                    int maxPacket = 8 * 1024 * 1024;
                    if (size <= 0 || size > maxPacket) throw new IOException("Invalid video frame size");
                    byte[] frame = new byte[12 + size]; System.arraycopy(frameHeader, 0, frame, 0, 12); input.readFully(frame, 12, size);
                    long sendingStarted = SystemClock.elapsedRealtime();
                    sendVideo(wire, frame);
                    sendingMillis += SystemClock.elapsedRealtime() - sendingStarted;
                    bytesSent += frame.length;
                    if ((frameHeader[0] & 0x40) == 0) {
                        ++frames;
                        long now = SystemClock.elapsedRealtime(), duration = now - statsStarted;
                        if (duration >= 5000) {
                            android.util.Log.i("DroidMirrorPerformance", "relay fps=" + (frames * 1000.0 / duration)
                                + " kbps=" + (bytesSent * 8.0 / duration) + " sendBlockedMs=" + sendingMillis
                                + " ackWaitMs=" + state.videoWindow.takeWaitMillis() + " inFlight=" + state.videoWindow.inFlightBytes()
                                + " window=" + state.videoWindow.capacityBytes() + " deliveredKbps=" + state.videoWindow.deliveredBytesPerSecond() * 8 / 1000);
                            statsStarted = now; frames = bytesSent = sendingMillis = 0;
                        }
                        if (!state.streamStarted.get()) {
                            state.startedElapsed = SystemClock.elapsedRealtime();
                            if (state.streamStarted.compareAndSet(false, true)) {
                                wire.event(BluetoothWire.STREAM_STARTED);
                                status("Streaming");
                            }
                        }
                        state.guard.frameSent();
                    }
                }
            } catch (EOFException captureEnded) {
                state.eventReady.await(300, TimeUnit.MILLISECONDS); // Allow the shell's oneway callback to reach this process.
            }
            if (!state.stopped && state.endEvent.get() != 0) {
                wire.event(state.endEvent.get());
                Thread.sleep(150); // Short best-effort radio drain; lock/recovery already happened.
            }
        } catch (Exception error) {
            android.util.Log.w("DroidMirrorBluetooth", "Bluetooth capture failed", error);
            if (wire != null && !state.streamStarted.get()) {
                try { wire.event(BluetoothWire.CAPTURE_FAILED); Thread.sleep(100); }
                catch (IOException | InterruptedException ignored) {}
            }
            status("Bluetooth session unavailable: " + error.getMessage());
        } finally {
            stopSession(); status("Ready for your paired Mac");
        }
    }
    private void startControls(SessionState state, InputStream peer, BluetoothWire wire) {
        ParcelFileDescriptor descriptor = state.controlPipe;
        new Thread(() -> {
            try (DataInputStream input = new DataInputStream(peer); OutputStream output = new FileOutputStream(descriptor.getFileDescriptor())) {
                byte[] bytes = new byte[4096];
                while (!state.stopped) {
                    int type = input.readUnsignedByte(); int count = input.readInt();
                    if (type == 1 && (count == 0 || count == 8)) {
                        if (count == 8) state.videoWindow.acknowledge(input.readLong());
                        state.lastPeerSeen = SystemClock.elapsedRealtime();
                        ShizukuDisplayClient guard = state.guard;
                        if (guard != null) guard.peerAlive();
                        // Never block incoming input/lease heartbeats behind video output.
                        state.heartbeatReply.set(true);
                    } else if (type == 2 && count == 40) {
                        byte[] nonce=new byte[32]; input.readFully(nonce);
                        long received=input.readLong();
                        WirelessVideoUpgrade upgrade=state.wirelessUpgrade;
                        if (upgrade!=null) upgrade.fallback(nonce,received);
                    } else if (type == 0 && count > 0 && count <= bytes.length) {
                        input.readFully(bytes, 0, count);
                        state.lastPeerSeen = SystemClock.elapsedRealtime();
                        ShizukuDisplayClient guard = state.guard;
                        if (guard != null) guard.peerAlive();
                        output.write(bytes, 0, count); output.flush();
                    } else throw new IOException("Invalid Bluetooth control envelope");
                }
            } catch (IOException error) {
                if (!state.stopped) android.util.Log.w("DroidMirrorBluetooth", "Input channel ended", error);
            } finally { synchronized (CaptureService.this) { if (current == state) stopSession(); } }
        }, "BluetoothInput").start();
        new Thread(() -> {
            try {
                while (!state.stopped) {
                    if (state.heartbeatReply.getAndSet(false)) wire.event(BluetoothWire.ALIVE);
                    // Video ACKs arrive every 250 ms. Return only a sparse
                    // liveness echo, avoiding constant bidirectional BLE airtime.
                    Thread.sleep(1000);
                }
            } catch (IOException | InterruptedException error) {
                if (!state.stopped) android.util.Log.w("DroidMirrorBluetooth", "Heartbeat replies ended", error);
            } finally { synchronized (CaptureService.this) { if (current == state) stopSession(); } }
        }, "BluetoothHeartbeatReplies").start();
        new Thread(() -> {
            try (InputStream input = new FileInputStream(descriptor.getFileDescriptor())) {
                byte[] bytes = new byte[4096]; int count;
                while (!state.stopped && (count = input.read(bytes)) != -1) {
                    wire.control(bytes, count);
                }
            } catch (IOException error) {
                if (!state.stopped) android.util.Log.w("DroidMirrorBluetooth", "Control replies ended", error);
            } finally { synchronized (CaptureService.this) { if (current == state) stopSession(); } }
        }, "BluetoothControlReplies").start();
    }
    private void sendVideo(BluetoothWire wire, byte[] bytes) throws IOException {
        wire.video(bytes);
    }
    private synchronized void stopSession() {
        SessionState state = current;
        if (state != null) {
            boolean wasStreaming = state.streamStarted.get() && !state.stopped;
            state.stopped = true;
            state.videoWindow.close();
            if (state.wirelessUpgrade != null) state.wirelessUpgrade.close();
            if (state.peerTransport != null) state.peerTransport.close();
            if (state.ble != null) state.ble.close();
            ShizukuDisplayClient active = state.guard; state.guard = null;
            if (active != null) active.close(); else if (!state.hasGuard && state.streamStarted.get()) auditEnd(state, false);
            try { if (state.inputPipe != null) state.inputPipe.close(); } catch (IOException ignored) {}
            state.inputPipe = null;
            try { if (state.controlPipe != null) state.controlPipe.close(); } catch (IOException ignored) {}
            state.controlPipe = null;
            if (wasStreaming) StreamNotifications.ended(this, state.token);
        }
        try { if (socket != null) socket.close(); } catch (IOException ignored) {}
        socket = null;
        if (listener != null) listener.disconnect();
    }
    private void auditEnd(SessionState state, boolean shellPosted) {
        if (!state.streamStarted.get() || !state.auditPosted.compareAndSet(false, true)) return;
        if (!shellPosted) SessionAudit.phone(this);
    }
    @Override public void onDestroy() {
        shutdown = true;
        if (bridge != null) { bridge.close(); bridge = null; }
        stopSession();
        if (listener != null) listener.close();
        if (watchdog != null) watchdog.shutdownNow();
        unregisterReceiver(screenActions);
        super.onDestroy();
    }
}
