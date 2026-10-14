package app.droidmirror.bluetooth;

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
    private static final UUID SERVICE = UUID.fromString("c356a44e-6f2b-4da9-85e5-397991b8a603");
    private volatile boolean shutdown;
    private volatile BluetoothServerSocket listener;
    private volatile BluetoothSocket socket;
    private static final class SessionState {
        final String token = UUID.randomUUID().toString();
        String peerName;
        volatile long startedElapsed;
        volatile boolean promotionDismissed;
        volatile ParcelFileDescriptor inputPipe;
        volatile ShizukuDisplayClient guard;
        volatile boolean stopped;
        volatile boolean hasGuard;
        final AtomicInteger endEvent = new AtomicInteger();
        final AtomicBoolean streamStarted = new AtomicBoolean();
        final AtomicBoolean auditPosted = new AtomicBoolean();
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
    private volatile long writeStarted;
    private Thread server;
    private ScheduledExecutorService watchdog;
    private final Object notificationLock = new Object();

    enum ReadyResult { START_REQUESTED, NOT_CONFIGURED, PERMISSION_REQUIRED, BACKGROUND_RESTRICTED, FAILED }

    static ReadyResult enableIfConfigured(Context context) {
        android.content.SharedPreferences settings = context.getSharedPreferences("ready", MODE_PRIVATE);
        if (!settings.getBoolean("enabled", false) || settings.getString("peer", "").isEmpty()) return ReadyResult.NOT_CONFIGURED;
        if (Build.VERSION.SDK_INT >= 31 && context.checkSelfPermission(Manifest.permission.BLUETOOTH_CONNECT) != PackageManager.PERMISSION_GRANTED) return ReadyResult.PERMISSION_REQUIRED;
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
        return new Notification.Builder(this, "capture").setSmallIcon(android.R.drawable.ic_menu_camera)
            .setContentTitle("DroidMirror Bluetooth").setContentText(text).setContentIntent(open)
            .setOngoing(true).setOnlyAlertOnce(true).build();
    }
    private void status(String text) {
        synchronized (notificationLock) {
            if (!shutdown) getSystemService(NotificationManager.class).notify(1, notification(text));
        }
    }
    @Override public int onStartCommand(Intent intent, int flags, int id) {
        if (intent != null && (StreamNotifications.DISCONNECT.equals(intent.getAction())
                || StreamNotifications.DISMISSED.equals(intent.getAction()))) {
            notificationAction(intent);
            // A stale PendingIntent must not start readiness after a process death.
            if (server == null) { stopSelfResult(id); return START_NOT_STICKY; }
            return START_STICKY;
        }
        if (!getSharedPreferences("ready", MODE_PRIVATE).getBoolean("enabled", false)) { stopSelf(); return START_NOT_STICKY; }
        if (Build.VERSION.SDK_INT >= 31 && checkSelfPermission(Manifest.permission.BLUETOOTH_CONNECT) != PackageManager.PERMISSION_GRANTED) {
            stopSelf(); return START_NOT_STICKY;
        }
        NotificationManager notifications = getSystemService(NotificationManager.class);
        notifications.createNotificationChannel(new NotificationChannel("capture", "Bluetooth readiness", NotificationManager.IMPORTANCE_LOW));
        synchronized (notificationLock) {
            if (Build.VERSION.SDK_INT >= 29) startForeground(1, notification("Ready for your paired Mac"), ServiceInfo.FOREGROUND_SERVICE_TYPE_CONNECTED_DEVICE);
            else startForeground(1, notification("Ready for your paired Mac"));
        }
        if (server != null) return START_STICKY;
        watchdog = Executors.newSingleThreadScheduledExecutor();
        watchdog.scheduleWithFixedDelay(() -> {
            if (writeStarted != 0 && SystemClock.elapsedRealtime() - writeStarted > 1000) stopSession();
        }, 100, 100, TimeUnit.MILLISECONDS);
        server = new Thread(this::listen, "BluetoothReady"); server.start();
        return START_STICKY;
    }
    private synchronized void notificationAction(Intent intent) {
        SessionState state = current;
        if (state == null || state.stopped || !state.streamStarted.get()
                || !state.token.equals(intent.getStringExtra(StreamNotifications.TOKEN))) return;
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
                String peer = getSharedPreferences("ready", MODE_PRIVATE).getString("peer", "");
                listener = adapter.listenUsingRfcommWithServiceRecord("DroidMirror video", SERVICE);
                BluetoothSocket candidate = listener.accept();
                if (!peer.equals(candidate.getRemoteDevice().getAddress()) || candidate.getRemoteDevice().getBondState() != BluetoothDevice.BOND_BONDED) {
                    candidate.close(); listener.close(); listener = null; continue;
                }
                socket = candidate; listener.close(); listener = null;
                serve();
            } catch (IOException | InterruptedException | RuntimeException error) {
                if (!shutdown) {
                    status("Waiting for Bluetooth and Shizuku");
                    try { Thread.sleep(1000); } catch (InterruptedException ignored) {}
                }
            } finally {
                stopSession();
                try { if (listener != null) listener.close(); } catch (IOException ignored) {}
                listener = null;
            }
        }
    }
    private void serve() {
        SessionState state = new SessionState(); current = state; writeStarted = 0;
        BluetoothWire wire = null;
        try {
            if (Build.VERSION.SDK_INT >= 31 && checkSelfPermission(Manifest.permission.BLUETOOTH_CONNECT) != PackageManager.PERMISSION_GRANTED)
                throw new SecurityException("Nearby Devices permission was revoked");
            String name = socket.getRemoteDevice().getName();
            state.peerName = name == null || name.trim().isEmpty() ? getString(R.string.stream_peer_fallback) : name;
            wire = new BluetoothWire(socket.getOutputStream());
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
            try (ParcelFileDescriptor output = pipe[1]) { state.guard.startVideo(output); }
            ByteArrayOutputStream header = new ByteArrayOutputStream();
            VideoWire.deviceHeader(new DataOutputStream(header), Build.MODEL);
            sendVideo(wire, header.toByteArray());
            try (DataInputStream input = new DataInputStream(new ParcelFileDescriptor.AutoCloseInputStream(state.inputPipe))) {
                byte[] codec = new byte[4]; input.readFully(codec); sendVideo(wire, codec);
                while (!shutdown && !state.stopped && state.endEvent.get() == 0) {
                    byte[] frameHeader = new byte[12]; input.readFully(frameHeader);
                    if ((frameHeader[0] & 0x80) != 0) { sendVideo(wire, frameHeader); continue; }
                    int size = ((frameHeader[8] & 255) << 24) | ((frameHeader[9] & 255) << 16) | ((frameHeader[10] & 255) << 8) | (frameHeader[11] & 255);
                    if (size <= 0 || size > VideoWire.MAX_PACKET) throw new IOException("Invalid video frame size");
                    byte[] frame = new byte[12 + size]; System.arraycopy(frameHeader, 0, frame, 0, 12); input.readFully(frame, 12, size);
                    sendVideo(wire, frame);
                    if ((frameHeader[0] & 0x40) == 0) {
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
                writeStarted = SystemClock.elapsedRealtime(); wire.event(state.endEvent.get()); writeStarted = 0;
                Thread.sleep(150); // Short best-effort radio drain; lock/recovery already happened.
            }
        } catch (Exception error) {
            if (wire != null && !state.streamStarted.get()) {
                try { writeStarted = SystemClock.elapsedRealtime(); wire.event(BluetoothWire.CAPTURE_FAILED); writeStarted = 0; Thread.sleep(100); }
                catch (IOException | InterruptedException ignored) {}
            }
            status("Capture unavailable. Keep Shizuku running and authorize it in setup.");
        } finally {
            stopSession(); status("Ready for your paired Mac");
        }
    }
    private void sendVideo(BluetoothWire wire, byte[] bytes) throws IOException {
        writeStarted = SystemClock.elapsedRealtime(); wire.video(bytes); writeStarted = 0;
    }
    private synchronized void stopSession() {
        SessionState state = current;
        if (state != null) {
            boolean wasStreaming = state.streamStarted.get() && !state.stopped;
            state.stopped = true;
            ShizukuDisplayClient active = state.guard; state.guard = null;
            if (active != null) active.close(); else if (!state.hasGuard && state.streamStarted.get()) auditEnd(state, false);
            try { if (state.inputPipe != null) state.inputPipe.close(); } catch (IOException ignored) {}
            state.inputPipe = null;
            if (wasStreaming) StreamNotifications.ended(this, state.token);
        }
        try { if (socket != null) socket.close(); } catch (IOException ignored) {}
        socket = null; writeStarted = 0;
    }
    private void auditEnd(SessionState state, boolean shellPosted) {
        if (!state.streamStarted.get() || !state.auditPosted.compareAndSet(false, true)) return;
        if (!shellPosted) SessionAudit.phone(this);
    }
    @Override public void onDestroy() {
        shutdown = true;
        stopSession();
        try { if (listener != null) listener.close(); } catch (IOException ignored) {}
        if (watchdog != null) watchdog.shutdownNow();
        unregisterReceiver(screenActions);
        super.onDestroy();
    }
}
