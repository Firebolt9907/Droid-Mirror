package app.droidmirror.bluetooth;

import android.app.*;
import android.Manifest;
import android.content.pm.PackageManager;
import android.bluetooth.*;
import android.content.Intent;
import android.content.pm.ServiceInfo;
import android.graphics.Rect;
import android.hardware.display.DisplayManager;
import android.hardware.display.VirtualDisplay;
import android.media.*;
import android.media.projection.*;
import android.os.*;
import android.view.Surface;
import android.view.WindowManager;
import java.io.*;
import java.nio.ByteBuffer;
import java.util.UUID;
import java.util.concurrent.*;

public final class CaptureService extends Service {
    private static final class QueuedPacket {
        final byte[] bytes;
        final long created = SystemClock.elapsedRealtime();
        QueuedPacket(byte[] bytes) { this.bytes = bytes; }
    }
    private static final UUID SERVICE = UUID.fromString("c356a44e-6f2b-4da9-85e5-397991b8a603");
    private volatile boolean stopping;
    private volatile BluetoothServerSocket listener;
    private volatile BluetoothSocket socket;
    private volatile long writeStarted;
    private MediaProjection projection;
    private Thread worker;
    private ScheduledExecutorService watchdog;

    @Override public IBinder onBind(Intent intent) { return null; }
    private Notification notification(String text) {
        return new Notification.Builder(this, "capture")
            .setSmallIcon(android.R.drawable.ic_menu_camera).setContentTitle("DroidMirror Bluetooth")
            .setContentText(text).setOngoing(true)
            .addAction(new Notification.Action.Builder(null, "Stop", PendingIntent.getService(this, 0,
                new Intent(this, CaptureService.class).setAction("stop"), PendingIntent.FLAG_IMMUTABLE)).build()).build();
    }
    @Override public int onStartCommand(Intent intent, int flags, int id) {
        if (intent == null || "stop".equals(intent.getAction())) { stopSelf(); return START_NOT_STICKY; }
        if (worker != null) { stopSelf(); return START_NOT_STICKY; }
        NotificationManager notifications = getSystemService(NotificationManager.class);
        notifications.createNotificationChannel(new NotificationChannel("capture", "Bluetooth screen capture", NotificationManager.IMPORTANCE_LOW));
        if (Build.VERSION.SDK_INT >= 29) startForeground(1, notification("Waiting for the selected Mac"), ServiceInfo.FOREGROUND_SERVICE_TYPE_MEDIA_PROJECTION);
        else startForeground(1, notification("Waiting for the selected Mac"));
        Intent permission = intent.getParcelableExtra("permission");
        String peer = intent.getStringExtra("peer");
        if (permission == null || peer == null) { stopSelf(); return START_NOT_STICKY; }
        try {
            projection = getSystemService(MediaProjectionManager.class).getMediaProjection(intent.getIntExtra("result", Activity.RESULT_CANCELED), permission);
            projection.registerCallback(new MediaProjection.Callback() {
                @Override public void onStop() { stopSelf(); }
            }, new Handler(getMainLooper()));
        } catch (RuntimeException error) { stopSelf(); return START_NOT_STICKY; }
        watchdog = Executors.newSingleThreadScheduledExecutor();
        watchdog.scheduleWithFixedDelay(() -> {
            if (writeStarted != 0 && SystemClock.elapsedRealtime() - writeStarted > 1000) abort();
        }, 100, 100, TimeUnit.MILLISECONDS);
        worker = new Thread(() -> capture(peer), "BluetoothCapture"); worker.start();
        return START_NOT_STICKY;
    }
    private void capture(String peer) {
        MediaCodec codec = null;
        VirtualDisplay display = null;
        Surface surface = null;
        Thread sender = null;
        try {
            if (Build.VERSION.SDK_INT >= 31 && checkSelfPermission(Manifest.permission.BLUETOOTH_CONNECT) != PackageManager.PERMISSION_GRANTED)
                throw new SecurityException("Bluetooth permission is required");
            BluetoothAdapter adapter = getSystemService(BluetoothManager.class).getAdapter();
            if (adapter == null || !adapter.isEnabled()) throw new IOException("Enable Bluetooth first");
            // Secure RFCOMM requires system bonding/encryption. Only the phone-selected Mac is accepted.
            listener = adapter.listenUsingRfcommWithServiceRecord("DroidMirror video", SERVICE);
            long deadline = SystemClock.elapsedRealtime() + 60000;
            while (!stopping && socket == null) {
                int remaining = (int)(deadline - SystemClock.elapsedRealtime());
                if (remaining <= 0) throw new IOException("Mac connection timed out");
                BluetoothSocket candidate = listener.accept(remaining);
                BluetoothDevice remote = candidate.getRemoteDevice();
                if (remote.getBondState() != BluetoothDevice.BOND_BONDED || !peer.equals(remote.getAddress())) {
                    candidate.close(); continue;
                }
                socket = candidate;
            }
            listener.close(); listener = null;
            if (stopping || socket == null) return;
            Rect bounds;
            if (Build.VERSION.SDK_INT >= 30) bounds = getSystemService(WindowManager.class).getMaximumWindowMetrics().getBounds();
            else {
                android.util.DisplayMetrics metrics = new android.util.DisplayMetrics();
                getSystemService(WindowManager.class).getDefaultDisplay().getRealMetrics(metrics);
                bounds = new Rect(0, 0, metrics.widthPixels, metrics.heightPixels);
            }
            int[] size = VideoWire.dimensions(bounds.width(), bounds.height());
            MediaFormat format = MediaFormat.createVideoFormat(MediaFormat.MIMETYPE_VIDEO_AVC, size[0], size[1]);
            format.setInteger(MediaFormat.KEY_COLOR_FORMAT, MediaCodecInfo.CodecCapabilities.COLOR_FormatSurface);
            format.setInteger(MediaFormat.KEY_BIT_RATE, 1_000_000);
            format.setInteger(MediaFormat.KEY_FRAME_RATE, 30);
            format.setFloat("max-fps-to-encoder", 30);
            // A static display still emits a small refresh frame once a second.
            format.setLong("repeat-previous-frame-after", 1_000_000);
            format.setInteger(MediaFormat.KEY_I_FRAME_INTERVAL, 2);
            format.setInteger(MediaFormat.KEY_BITRATE_MODE, MediaCodecInfo.EncoderCapabilities.BITRATE_MODE_CBR);
            format.setInteger(MediaFormat.KEY_PROFILE, MediaCodecInfo.CodecProfileLevel.AVCProfileBaseline);
            codec = MediaCodec.createEncoderByType(MediaFormat.MIMETYPE_VIDEO_AVC);
            codec.configure(format, null, null, MediaCodec.CONFIGURE_FLAG_ENCODE);
            surface = codec.createInputSurface(); codec.start();
            display = projection.createVirtualDisplay("DroidMirror Bluetooth", size[0], size[1],
                getResources().getDisplayMetrics().densityDpi, DisplayManager.VIRTUAL_DISPLAY_FLAG_AUTO_MIRROR,
                surface, null, null);
            DataOutputStream out = new DataOutputStream(socket.getOutputStream());
            writeStarted = SystemClock.elapsedRealtime();
            VideoWire.header(out, Build.MODEL, size[0], size[1]);
            writeStarted = 0;
            // At most four packets can wait. Never discard H.264 reference frames:
            // if the transport falls behind, close and require fresh capture consent.
            ArrayBlockingQueue<QueuedPacket> packets = new ArrayBlockingQueue<>(4);
            sender = new Thread(() -> {
                try {
                    while (!stopping) {
                        QueuedPacket packet = packets.poll(100, TimeUnit.MILLISECONDS);
                        if (packet == null) continue;
                        if (SystemClock.elapsedRealtime() - packet.created > 500) throw new IOException("Stale video packet");
                        writeStarted = SystemClock.elapsedRealtime();
                        out.write(packet.bytes); out.flush();
                        writeStarted = 0;
                    }
                } catch (IOException | InterruptedException error) { abort(); }
            }, "BluetoothVideoWriter"); sender.start();
            getSystemService(NotificationManager.class).notify(1, notification("Streaming 480p · up to 30 fps · 1 Mbps"));
            MediaCodec.BufferInfo info = new MediaCodec.BufferInfo();
            while (!stopping) {
                int index = codec.dequeueOutputBuffer(info, 100000);
                if (index < 0) continue;
                try {
                    if (info.size > 0) {
                        if (info.size > VideoWire.MAX_PACKET) throw new IOException("Oversized video frame");
                        ByteBuffer encoded = codec.getOutputBuffer(index);
                        encoded.position(info.offset); encoded.limit(info.offset + info.size);
                        byte[] payload = new byte[info.size]; encoded.get(payload);
                        byte[] packet = VideoWire.packet(payload, info.presentationTimeUs,
                            (info.flags & MediaCodec.BUFFER_FLAG_CODEC_CONFIG) != 0,
                            (info.flags & MediaCodec.BUFFER_FLAG_KEY_FRAME) != 0);
                        if (!packets.offer(new QueuedPacket(packet), 100, TimeUnit.MILLISECONDS)) throw new IOException("Bluetooth video queue full");
                    }
                } finally { codec.releaseOutputBuffer(index, false); }
                if ((info.flags & MediaCodec.BUFFER_FLAG_END_OF_STREAM) != 0) break;
            }
        } catch (IOException | InterruptedException | RuntimeException error) {
            // Keep screen content and Bluetooth peer identifiers out of logs.
        } finally {
            abort();
            if (sender != null) sender.interrupt();
            if (display != null) display.release();
            if (codec != null) { try { codec.stop(); } catch (RuntimeException ignored) {} codec.release(); }
            if (surface != null) surface.release();
            stopSelf();
        }
    }
    private void abort() {
        stopping = true;
        try { if (listener != null) listener.close(); } catch (IOException ignored) {}
        try { if (socket != null) socket.close(); } catch (IOException ignored) {}
    }
    @Override public void onDestroy() {
        abort();
        if (watchdog != null) watchdog.shutdownNow();
        if (projection != null) projection.stop();
        super.onDestroy();
    }
}
