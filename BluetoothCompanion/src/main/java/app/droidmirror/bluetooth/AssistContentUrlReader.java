package app.droidmirror.bluetooth;

import android.app.assist.AssistContent;
import android.os.Binder;
import android.os.Bundle;
import android.os.Parcel;
import android.os.RemoteException;
import java.lang.reflect.Field;
import java.lang.reflect.Proxy;
import java.util.concurrent.CountDownLatch;
import java.util.concurrent.TimeUnit;

/** Requests app-provided web content only: no screenshot or assist view structure. */
final class AssistContentUrlReader {
    static String read(Object service, Class<?> api, int taskId) throws Exception {
        Class<?> receiverApi = Class.forName("android.app.IAssistDataReceiver");
        Field transaction = Class.forName("android.app.IAssistDataReceiver$Stub")
                .getDeclaredField("TRANSACTION_onHandleAssistData");
        transaction.setAccessible(true);
        int dataTransaction = transaction.getInt(null);
        CountDownLatch done = new CountDownLatch(1);
        String[] url = new String[1];
        Binder receiver = new Binder() {
            @Override protected boolean onTransact(int code, Parcel data, Parcel reply, int flags)
                    throws RemoteException {
                if (code == INTERFACE_TRANSACTION) {
                    if (reply != null) reply.writeString("android.app.IAssistDataReceiver");
                    return true;
                }
                if (code != dataTransaction) return super.onTransact(code, data, reply, flags);
                data.enforceInterface("android.app.IAssistDataReceiver");
                try {
                    Bundle bundle = data.readTypedObject(Bundle.CREATOR);
                    AssistContent content = bundle == null ? null : bundle.getParcelable("content");
                    // Default assist content can inherit an old launch URL. Only trust a URL
                    // explicitly supplied by the activity for its current content.
                    if (content != null && content.isAppProvidedWebUri() && content.getWebUri() != null) {
                        String candidate = content.getWebUri().toString();
                        if (TaskUrlResolver.webUrl(candidate)) url[0] = candidate;
                    }
                } catch (RuntimeException ignored) {
                    // Missing, unsupported or malformed app content means no suggestion.
                } finally { done.countDown(); }
                return true;
            }
        };
        Object proxy = Proxy.newProxyInstance(receiverApi.getClassLoader(), new Class<?>[]{receiverApi},
                (object, method, args) -> {
                    if (method.getName().equals("asBinder")) return receiver;
                    if (method.getName().equals("hashCode")) return System.identityHashCode(object);
                    if (method.getName().equals("equals")) return object == args[0];
                    if (method.getName().equals("toString")) return "DroidMirrorAssistUrlReceiver";
                    return null;
                });
        boolean accepted = (Boolean) api.getMethod("requestAssistDataForTask", receiverApi,
                int.class, String.class, String.class, boolean.class)
                .invoke(service, proxy, taskId, "com.android.shell", null, false /* fetchStructure */);
        // Every lookup owns its receiver; a late reply can never update a later lookup.
        return accepted && done.await(1500, TimeUnit.MILLISECONDS) ? url[0] : null;
    }
}
