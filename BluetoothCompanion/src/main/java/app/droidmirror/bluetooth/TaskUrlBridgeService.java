package app.droidmirror.bluetooth;

import android.content.Context;
import android.os.Binder;

/** Independent Shizuku service: task discovery never takes a mirror/display lease. */
public final class TaskUrlBridgeService extends ITaskUrlBridge.Stub {
    private final Context context;
    public TaskUrlBridgeService() { this(null); }
    public TaskUrlBridgeService(Context context) { this.context = context; }
    @Override public boolean openNotification(android.app.PendingIntent intent) {
        int uid = Binder.getCallingUid();
        if (uid != android.os.Process.myUid() &&
                (context == null || uid != context.getApplicationInfo().uid)) throw new SecurityException("Invalid notification caller");
        long identity = Binder.clearCallingIdentity();
        try {
            // Shizuku dispatches on Binder threads without loopers. scrcpy's
            // system context creates an ActivityThread/Handler on first use.
            if (android.os.Looper.myLooper() == null) android.os.Looper.prepare();
            Context shell = com.genymobile.scrcpy.FakeContext.get().getBaseContext().createPackageContext("com.android.shell", 0);
            if (intent == null || keyguardLocked()) return false;
            android.os.Bundle options = null;
            if (android.os.Build.VERSION.SDK_INT >= 34) {
                options = android.app.ActivityOptions.makeBasic().setPendingIntentBackgroundActivityStartMode(
                    android.os.Build.VERSION.SDK_INT >= 36 ?
                    android.app.ActivityOptions.MODE_BACKGROUND_ACTIVITY_START_ALLOW_ALWAYS :
                    android.app.ActivityOptions.MODE_BACKGROUND_ACTIVITY_START_ALLOWED).toBundle();
            }
            // Send the original opaque capability as shell. The app validates
            // the authenticated click and current notification immediately before IPC.
            intent.send(shell, 0, null, null, null, null, options);
            android.util.Log.i("DroidMirrorNotifications", "Notification open sent via Shizuku v6");
            return true;
        } catch (Exception failure) {
            android.util.Log.w("DroidMirrorNotifications", "Notification open failed", failure);
            return false;
        } finally { Binder.restoreCallingIdentity(identity); }
    }
    private static boolean keyguardLocked() throws Exception {
        // KeyguardManager initializes WindowManagerGlobal, which requires app
        // shared memory unavailable in an Android 17 shell user-service process.
        android.os.IBinder binder = (android.os.IBinder) Class.forName("android.os.ServiceManager")
            .getMethod("getService", String.class).invoke(null, "window");
        Object window = Class.forName("android.view.IWindowManager$Stub")
            .getMethod("asInterface", android.os.IBinder.class).invoke(null, binder);
        return (Boolean) window.getClass().getMethod("isKeyguardLocked").invoke(window);
    }
    @Override public boolean openLauncher(String component) {
        int uid = Binder.getCallingUid();
        if (uid != android.os.Process.myUid() &&
                (context == null || uid != context.getApplicationInfo().uid)) throw new SecurityException("Invalid launcher caller");
        android.content.ComponentName target = android.content.ComponentName.unflattenFromString(component);
        if (target == null || !component.matches("[A-Za-z0-9_.$]+/[A-Za-z0-9_.$]+")) return false;
        long identity = Binder.clearCallingIdentity();
        try {
            if (keyguardLocked()) return false;
            if (android.os.Looper.myLooper() == null) android.os.Looper.prepare();
            android.content.pm.PackageManager pm = com.genymobile.scrcpy.FakeContext.get().getPackageManager();
            android.content.Intent intent = new android.content.Intent(android.content.Intent.ACTION_MAIN)
                .addCategory(android.content.Intent.CATEGORY_LAUNCHER).setComponent(target);
            if (pm.queryIntentActivities(intent, 0).isEmpty()) return false;
            Process launch = new ProcessBuilder("am", "start", "-W", "--user", "current", "-a",
                android.content.Intent.ACTION_MAIN, "-c", android.content.Intent.CATEGORY_LAUNCHER,
                "-n", target.flattenToString()).redirectErrorStream(true).start();
            if (!launch.waitFor(5, java.util.concurrent.TimeUnit.SECONDS)) { launch.destroyForcibly(); return false; }
            String output = readOutput(launch);
            boolean success = launch.exitValue() == 0 && !output.contains("Error:") && !output.contains("Exception");
            android.util.Log.i("DroidMirrorApps", "Launcher displayed via Shizuku v8: " + success);
            return success;
        } catch (Exception failure) { return false; }
        finally { Binder.restoreCallingIdentity(identity); }
    }
    @Override public String readTask() {
        long identity = Binder.clearCallingIdentity();
        try { return TaskUrlReader.read(); }
        catch (Exception | LinkageError unavailable) { return ""; }
        finally { Binder.restoreCallingIdentity(identity); }
    }
    @Override public String readHandoffDiagnostics() {
        long identity = Binder.clearCallingIdentity();
        Process process = null;
        try {
            // Metadata only: never call push-task or requestHandoff.
            int user = (Integer) Class.forName("android.app.ActivityManager")
                    .getMethod("getCurrentUser").invoke(null);
            process = new ProcessBuilder("cmd", "task_continuity", "handoff", "list-tasks",
                    Integer.toString(user)).redirectErrorStream(true).start();
            final Process child = process;
            java.util.concurrent.FutureTask<String> output = new java.util.concurrent.FutureTask<>(() -> {
                try (java.io.InputStream input = child.getInputStream()) {
                    byte[] bytes = input.readNBytes(65537);
                    if (bytes.length > 65536) throw new java.io.IOException("oversize");
                    return new String(bytes, java.nio.charset.StandardCharsets.UTF_8);
                }
            });
            Thread reader = new Thread(output, "handoff-metadata");
            reader.setDaemon(true);
            reader.start();
            String listing = output.get(3, java.util.concurrent.TimeUnit.SECONDS);
            if (!process.waitFor(1, java.util.concurrent.TimeUnit.SECONDS) || process.exitValue() != 0)
                return "{\"status\":\"unavailable\"}";
            java.util.Set<String> packages = HandoffDiagnostics.packages(listing);
            return new org.json.JSONObject().put("status", packages.isEmpty() ? "no_recognized_packages" : "eligible")
                    .put("user", user).put("packages", new org.json.JSONArray(packages)).toString();
        } catch (Exception | LinkageError unavailable) {
            return "{\"status\":\"unavailable\"}";
        } finally {
            if (process != null) process.destroyForcibly();
            Binder.restoreCallingIdentity(identity);
        }
    }
    @Override public boolean openBrowser(String url) {
        if (!TaskUrlResolver.webUrl(url)) return false;
        long identity = Binder.clearCallingIdentity();
        try {
            // Use the browser role explicitly so Android app links cannot divert the URL.
            Process role = new ProcessBuilder("cmd", "role", "get-role-holders", "--user", "current",
                    "android.app.role.BROWSER").redirectErrorStream(true).start();
            if (!role.waitFor(3, java.util.concurrent.TimeUnit.SECONDS)) { role.destroyForcibly(); return false; }
            String pkg = readOutput(role).trim();
            if (role.exitValue() != 0 || !pkg.matches("[A-Za-z0-9_]+(?:\\.[A-Za-z0-9_]+)+")) return false;
            Process launch = new ProcessBuilder("am", "start", "--user", "current", "-W",
                    "-a", "android.intent.action.VIEW", "-c", "android.intent.category.BROWSABLE",
                    "-p", pkg, "-d", url).redirectErrorStream(true).start();
            if (!launch.waitFor(5, java.util.concurrent.TimeUnit.SECONDS)) { launch.destroyForcibly(); return false; }
            String result = readOutput(launch);
            return launch.exitValue() == 0 && !result.contains("Error:") && !result.contains("Exception");
        } catch (Exception unavailable) { return false; }
        finally { Binder.restoreCallingIdentity(identity); }
    }
    private static String readOutput(Process process) throws java.io.IOException {
        StringBuilder output = new StringBuilder();
        try (java.io.BufferedReader reader = new java.io.BufferedReader(new java.io.InputStreamReader(
                process.getInputStream(), java.nio.charset.StandardCharsets.UTF_8))) {
            String line;
            while ((line = reader.readLine()) != null) output.append(line).append('\n');
        }
        return output.toString();
    }
    @Override public void destroy() { System.exit(0); }
}
