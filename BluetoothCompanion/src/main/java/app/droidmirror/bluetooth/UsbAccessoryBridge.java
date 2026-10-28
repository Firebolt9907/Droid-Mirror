package app.droidmirror.bluetooth;

import android.content.Context;
import android.hardware.usb.UsbAccessory;
import android.hardware.usb.UsbManager;
import android.net.LocalSocket;
import android.net.LocalSocketAddress;
import android.os.ParcelFileDescriptor;
import java.io.*;

/** Carries the existing nonce/proof-authenticated video protocol over AOA bulk USB. */
final class UsbAccessoryBridge implements AutoCloseable {
    private final UsbManager manager;
    private final Thread worker;
    private volatile boolean closed;
    private volatile LocalSocket socket;
    private volatile ParcelFileDescriptor accessory;
    UsbAccessoryBridge(Context context) {
        manager=context.getSystemService(UsbManager.class);
        worker=new Thread(this::run,"UsbAccessoryVideo"); worker.setDaemon(true); worker.start();
    }
    static boolean matches(UsbAccessory accessory) {
        return "DroidMirror".equals(accessory.getManufacturer()) && "DroidMirror USB".equals(accessory.getModel());
    }
    private void run() {
        while (!closed) {
            try {
                UsbAccessory[] list=manager==null ? null : manager.getAccessoryList();
                if (list!=null) for (UsbAccessory candidate:list) {
                    if (closed || !matches(candidate) || !manager.hasPermission(candidate)) continue;
                    relay(candidate);
                }
                Thread.sleep(500);
            } catch (InterruptedException interrupted) { return; }
            catch (IOException | RuntimeException unavailable) {
                if (!closed) android.util.Log.d("DroidMirrorUSB","USB video not ready",unavailable);
                try { Thread.sleep(500); } catch (InterruptedException interrupted) { return; }
            }
        }
    }
    private void relay(UsbAccessory candidate) throws IOException {
        // Connect first: do not consume accessory data before a live capture
        // session has installed its authenticated upgrade endpoint.
        LocalSocket local=new LocalSocket(); socket=local;
        ParcelFileDescriptor fd=null;
        try {
            local.connect(new LocalSocketAddress("droidmirror_video_upgrade",LocalSocketAddress.Namespace.ABSTRACT));
            if (closed) return;
            fd=manager.openAccessory(candidate); accessory=fd;
            if (fd==null) throw new IOException("USB accessory unavailable");
            final InputStream usbInput=new FileInputStream(fd.getFileDescriptor());
            final OutputStream usbOutput=new FileOutputStream(fd.getFileDescriptor());
            Thread upstream=new Thread(() -> {
                try { copy(usbInput,local.getOutputStream()); }
                catch (IOException ignored) { }
                finally { abort(local); }
            },"UsbAccessoryInput"); upstream.setDaemon(true); upstream.start();
            copy(local.getInputStream(),usbOutput);
        } finally {
            abort(local); socket=null;
            if (fd!=null) fd.close(); accessory=null;
        }
    }
    private void copy(InputStream input, OutputStream output) throws IOException {
        // AOA reads must consume an entire USB transfer (up to 16 KiB).
        byte[] bytes=new byte[16384];
        while (!closed) {
            int count=input.read(bytes);
            if (count<0) break;
            output.write(bytes,0,count); output.flush();
        }
    }
    private static void abort(LocalSocket socket) {
        if (socket==null) return;
        try { socket.shutdownInput(); } catch (IOException ignored) { }
        try { socket.shutdownOutput(); } catch (IOException ignored) { }
        try { socket.close(); } catch (IOException ignored) { }
    }
    public void close() {
        closed=true; worker.interrupt(); abort(socket);
        ParcelFileDescriptor fd=accessory;
        if (fd!=null) try { fd.close(); } catch (IOException ignored) { }
    }
}
