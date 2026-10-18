package app.droidmirror.bluetooth;

import android.content.ComponentName;
import android.content.Intent;
import java.util.List;
import org.json.JSONObject;

/** Shell-only structured task lookup. Never launches activities or requests handoff. */
public final class TaskUrlReader {
    public static String read() throws Exception {
        Class<?> manager = Class.forName("android.app.ActivityTaskManager");
        Object service = manager.getMethod("getService").invoke(null);
        Class<?> api = Class.forName("android.app.IActivityTaskManager");
        List<?> tasks = (List<?>) api.getMethod("getTasks", int.class, boolean.class, boolean.class, int.class)
                .invoke(service, 1, false, false, 0);
        if (tasks.isEmpty()) return "";
        Object task = tasks.get(0);
        Class<?> type = task.getClass();
        ComponentName top = (ComponentName) type.getField("topActivity").get(task);
        Intent intent = (Intent) type.getField("baseIntent").get(task);
        // A browser or another app above a task's original owner must not inherit its URL.
        if (top == null || intent == null || intent.getComponent() == null
                || !top.getPackageName().equals(intent.getComponent().getPackageName())) return "";
        String url = TaskUrlResolver.resolve(top.getPackageName(), top.getClassName(),
                intent.getAction(), intent.getDataString());
        if (url == null) return "";
        return new JSONObject().put("url", url).put("package", top.getPackageName())
                .put("taskId", type.getField("taskId").getInt(task)).toString();
    }
    public static void main(String[] args) throws Exception { System.out.println(read()); }
}
