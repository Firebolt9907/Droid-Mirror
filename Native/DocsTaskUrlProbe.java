import android.content.ComponentName;
import android.content.Intent;
import android.net.Uri;
import org.json.JSONObject;
import java.util.List;

/** Read-only ADB shell probe. Uses hidden APIs; does not initiate a handoff. */
public final class DocsTaskUrlProbe {
    public static void main(String[] args) throws Exception {
        if (args.length != 1) throw new IllegalArgumentException("Supply the Docs task ID");
        int wanted = Integer.parseInt(args[0]);
        Class<?> manager = Class.forName("android.app.ActivityTaskManager");
        Object service = manager.getMethod("getService").invoke(null);
        Class<?> api = Class.forName("android.app.IActivityTaskManager");
        Object slice = api.getMethod("getRecentTasks", int.class, int.class, int.class)
                .invoke(service, 100, 0, 0);
        List<?> tasks = (List<?>) slice.getClass().getMethod("getList").invoke(slice);
        for (Object task : tasks) {
            Class<?> type = task.getClass();
            if (type.getField("taskId").getInt(task) != wanted) continue;
            Intent intent = (Intent) type.getField("baseIntent").get(task);
            ComponentName component = intent == null ? null : intent.getComponent();
            Uri uri = intent == null ? null : intent.getData();
            if (component == null || !"com.google.android.apps.docs.editors.docs".equals(component.getPackageName())
                    || !component.getClassName().endsWith(".KixEditorActivity")) {
                throw new IllegalStateException("Task is not a Google Docs editor");
            }
            if (uri == null || !"content".equals(uri.getScheme()) || !"uniqueId".equals(uri.getAuthority())
                    || uri.getPathSegments().size() != 1) {
                throw new IllegalStateException("Unsupported Docs task URI; cannot infer a URL");
            }
            String id = uri.getPathSegments().get(0);
            if (!id.matches("[A-Za-z0-9_-]+")) throw new IllegalStateException("Invalid document ID");
            JSONObject result = new JSONObject();
            result.put("taskId", wanted);
            result.put("package", component.getPackageName());
            result.put("source", "recentTask.baseIntent.data (not handoff payload)");
            result.put("url", "https://docs.google.com/document/d/" + id + "/edit");
            System.out.println(result);
            return;
        }
        throw new IllegalStateException("Task not found in user 0 recent tasks");
    }
}
