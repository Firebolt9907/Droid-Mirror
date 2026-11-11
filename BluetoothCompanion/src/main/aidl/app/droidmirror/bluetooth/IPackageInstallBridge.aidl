package app.droidmirror.bluetooth;
import android.os.ParcelFileDescriptor;
interface IPackageInstallBridge {
    String install(in ParcelFileDescriptor apk, long size);
}
