package app.droidmirror.bluetooth;

import android.bluetooth.*;
import android.content.Context;
import android.os.ParcelFileDescriptor;
import java.io.*;
import java.util.concurrent.atomic.AtomicReference;

/** Explicit shell-only diagnostic on a separate PSM; never captures or stores a screen. */
public final class ClassicL2capBenchmark {
    public static void main(String[] args) throws Exception {
        if (android.os.Process.myUid() != 2000 || args.length != 3)
            throw new IllegalArgumentException("Run as shell: SELECTED_MAC PACKET_BYTES direct|pipe");
        android.os.Looper.prepareMainLooper(); PrivilegedCapture.initialize();
        // Framework callbacks need a running main Looper, as in the Shizuku daemon.
        // Blocking accept() on that Looper prevents a valid transport measurement.
        new Thread(() -> {
            try { run(args); System.exit(0); }
            catch (Exception error) { error.printStackTrace(); System.exit(1); }
        }, "ClassicBenchmark").start();
        android.os.Looper.loop();
    }
    private static void run(String[] args) throws Exception {
        String peer = args[0]; int size = Integer.parseInt(args[1]); boolean pipe = "pipe".equals(args[2]);
        if (!BluetoothAdapter.checkBluetoothAddress(peer) || (size != 256 && size != 672)
                || (!pipe && !"direct".equals(args[2]))) throw new IllegalArgumentException("Invalid benchmark settings");
        if (android.os.Build.VERSION.SDK_INT >= 31) {
            Class<?> init = Class.forName("android.bluetooth.BluetoothFrameworkInitializer");
            if (init.getMethod("getBluetoothServiceManager").invoke(null) == null) {
                Class<?> manager = Class.forName("android.os.BluetoothServiceManager");
                init.getMethod("setBluetoothServiceManager", manager).invoke(null, manager.getConstructor().newInstance());
            }
        }
        Context shell = com.genymobile.scrcpy.FakeContext.get().getBaseContext().createPackageContext("com.android.shell", 0);
        if (android.os.Build.VERSION.SDK_INT >= 31
                && shell.checkSelfPermission(android.Manifest.permission.BLUETOOTH_CONNECT) != android.content.pm.PackageManager.PERMISSION_GRANTED)
            throw new SecurityException("Shell Bluetooth permission unavailable");
        BluetoothAdapter adapter = shell.getSystemService(BluetoothManager.class).getAdapter();
        try (BluetoothServerSocket listener = (BluetoothServerSocket)BluetoothAdapter.class
                .getMethod("listenUsingL2capOn", int.class).invoke(adapter, 0x1003)) {
            System.out.println("BENCH READY psm=0x1003 size=" + size + " mode=" + args[2]);
            // Shell SELinux forbids setsockopt(SO_RCVTIMEO) on this framework's
            // local socket. Bound accept by closing it from a watchdog instead.
            java.util.concurrent.ScheduledExecutorService watchdog = java.util.concurrent.Executors.newSingleThreadScheduledExecutor();
            watchdog.schedule(() -> { try { listener.close(); } catch (IOException ignored) {} }, 30, java.util.concurrent.TimeUnit.SECONDS);
            try (BluetoothSocket socket = listener.accept()) {
                watchdog.shutdownNow();
                BluetoothDevice device=socket.getRemoteDevice();
                if (!peer.equals(device.getAddress()) || device.getBondState()!=BluetoothDevice.BOND_BONDED)
                    throw new SecurityException("Benchmark accepts only the selected bonded Mac");
                System.out.println("BENCH CONNECTED txMtu=" + socket.getMaxTransmitPacketSize() + " rxMtu=" + socket.getMaxReceivePacketSize());
                OutputStream radio=socket.getOutputStream(), destination=radio;
                Thread relay=null; AtomicReference<Exception> failure=new AtomicReference<>();
                ParcelFileDescriptor[] descriptors=null;
                if (pipe) {
                    descriptors=ParcelFileDescriptor.createPipe();
                    InputStream source=new ParcelFileDescriptor.AutoCloseInputStream(descriptors[0]);
                    destination=new ParcelFileDescriptor.AutoCloseOutputStream(descriptors[1]);
                    relay=new Thread(() -> {
                        try (InputStream input=source) {
                            byte[] buffer=new byte[4096]; int count;
                            while ((count=input.read(buffer))!=-1) radio.write(buffer,0,count);
                        } catch (Exception error) { failure.set(error); try { source.close(); } catch (IOException ignored) {} }
                    }, "BenchmarkPipeRelay"); relay.start();
                }
                long bytes=0, started=System.nanoTime(), until=started+10000000000L;
                byte[] packet=new byte[size];
                while (System.nanoTime()<until && failure.get()==null) {
                    for (int i=0;i<size;++i) packet[i]=(byte)(bytes+i);
                    destination.write(packet); bytes+=size;
                }
                if (pipe) { destination.close(); relay.join(5000); if (relay.isAlive()) throw new IOException("Relay did not drain"); }
                if (failure.get()!=null) throw failure.get();
                long elapsed=System.nanoTime()-started;
                System.out.println("BENCH SENT bytes="+bytes+" elapsedMs="+elapsed/1000000+" mbps="+(bytes*8000.0/elapsed));
                Thread.sleep(1500); // Let already queued bytes drain before closing; Mac measures actual receives.
            } finally { watchdog.shutdownNow(); }
        }
    }
}
