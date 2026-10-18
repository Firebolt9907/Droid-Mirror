package app.droidmirror.bluetooth;

import android.content.Context;
import android.os.Binder;

/** Independent Shizuku service: task discovery never takes a mirror/display lease. */
public final class TaskUrlBridgeService extends ITaskUrlBridge.Stub {
    public TaskUrlBridgeService() {}
    public TaskUrlBridgeService(Context context) {}
    @Override public String readTask() {
        long identity = Binder.clearCallingIdentity();
        try { return TaskUrlReader.read(); }
        catch (Exception | LinkageError unavailable) { return ""; }
        finally { Binder.restoreCallingIdentity(identity); }
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
