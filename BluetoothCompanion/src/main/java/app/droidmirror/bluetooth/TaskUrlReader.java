package app.droidmirror.bluetooth;

import android.content.ComponentName;
import android.content.Intent;
import java.util.List;
import org.json.JSONObject;

/** Shell-only structured task lookup. Never launches activities or requests handoff. */
public final class TaskUrlReader {
    private static Object topTask(Object service, Class<?> api) throws Exception {
        List<?> tasks = (List<?>) api.getMethod("getTasks", int.class, boolean.class, boolean.class, int.class)
                .invoke(service, 1, false, false, 0);
        return tasks.isEmpty() ? null : tasks.get(0);
    }
    public static String read() throws Exception {
        Class<?> manager = Class.forName("android.app.ActivityTaskManager");
        Object service = manager.getMethod("getService").invoke(null);
        Class<?> api = Class.forName("android.app.IActivityTaskManager");
        Object task = topTask(service, api);
        if (task == null) return "";
        Class<?> type = task.getClass();
        ComponentName top = (ComponentName) type.getField("topActivity").get(task);
        Intent intent = (Intent) type.getField("baseIntent").get(task);
        // A browser or another app above a task's original owner must not inherit its URL.
        if (top == null || intent == null || intent.getComponent() == null
                || !top.getPackageName().equals(intent.getComponent().getPackageName())) return "";
        int taskId = type.getField("taskId").getInt(task);
        String intentUrl = TaskUrlResolver.resolve(top.getPackageName(), top.getClassName(),
                intent.getAction(), intent.getDataString());
        String assistUrl = null;
        try { assistUrl = AssistContentUrlReader.read(service, api, taskId); }
        catch (Exception | LinkageError unavailable) { /* A supported Docs adapter can still work. */ }
        String url = TaskUrlResolver.currentUrl(assistUrl, intent.getDataString(), intentUrl);
        if (url == null) return "";
        Object current = topTask(service, api);
        if (current == null || current.getClass().getField("taskId").getInt(current) != taskId
                || !top.equals(current.getClass().getField("topActivity").get(current))) return "";
        return new JSONObject().put("url", url).put("package", top.getPackageName())
                .put("taskId", taskId).toString();
    }
    public static void main(String[] args) throws Exception { System.out.println(read()); }
}
