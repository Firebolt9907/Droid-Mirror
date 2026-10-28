package app.droidmirror.bluetooth;
import java.nio.file.*;
import java.nio.charset.StandardCharsets;
import java.util.concurrent.TimeUnit;
public final class HapticRestoreWatchdogTest {
    static void check(boolean value) { if (!value) throw new AssertionError(); }
    static void write(Path path, String value) throws Exception { Files.write(path,value.getBytes(StandardCharsets.UTF_8)); }
    static String read(Path path) throws Exception { return new String(Files.readAllBytes(path),StandardCharsets.UTF_8).trim(); }
    static void executable(Path dir, String name, String script) throws Exception {
        Path path=dir.resolve(name); write(path,"#!/bin/bash\n"+script); check(path.toFile().setExecutable(true));
    }
    public static void main(String[] args) throws Exception {
        Path dir=Files.createTempDirectory("haptic-restore-test-");
        try {
            executable(dir,"settings","case \"$3\" in get) cat \"$HAPTIC_TEST_STATE\";; put) printf '%s\\n' \"$6\" > \"$HAPTIC_TEST_STATE\";; delete) echo null > \"$HAPTIC_TEST_STATE\"; touch \"$HAPTIC_TEST_STATE.deleted\";; *) exit 2;; esac\n");
            executable(dir,"getprop","cat \"$HAPTIC_TEST_TAGS\"\n");
            executable(dir,"atrace","touch \"$HAPTIC_TEST_STOP\"\n");
            executable(dir,"log","exit 0\n");
            for (String scenario : new String[]{"stop","death","timeout","user-edit","foreign-trace","disabled","app-default"}) {
                Path state=dir.resolve("state"), tags=dir.resolve("tags"), stop=dir.resolve("stopped");
                write(state,scenario.equals("user-edit")?"2":scenario.equals("app-default")?"null":"0"); write(tags,scenario.equals("foreign-trace")?"9":"8"); Files.deleteIfExists(stop);
                Files.deleteIfExists(dir.resolve("state.deleted"));
                ProcessBuilder builder=new ProcessBuilder("/bin/bash","-c",SilentHaptics.RECOVERY,"haptic-recovery","0",scenario.equals("disabled")?"0":"absent","8");
                builder.environment().put("PATH",dir+":/usr/bin:/bin");
                builder.environment().put("HAPTIC_TEST_STATE",state.toString()); builder.environment().put("HAPTIC_TEST_TAGS",tags.toString()); builder.environment().put("HAPTIC_TEST_STOP",stop.toString());
                Process process=builder.redirectErrorStream(true).start();
                if (scenario.equals("stop")) process.getOutputStream().write("alive\nstop\n".getBytes(StandardCharsets.US_ASCII));
                if (!scenario.equals("timeout")) process.getOutputStream().close();
                check(process.waitFor(8,TimeUnit.SECONDS) && process.exitValue()==0);
                check(read(state).equals(scenario.equals("user-edit")?"2":scenario.equals("disabled")?"0":"null"));
                check(Files.exists(stop)!=scenario.equals("foreign-trace"));
                if (scenario.equals("app-default")) check(Files.exists(dir.resolve("state.deleted")));
            }
            System.out.println("PASS: production watchdog script stop, parent EOF, heartbeat timeout, user edits, trace ownership and disabled baseline");
        } finally {
            try (java.util.stream.Stream<Path> files=Files.walk(dir)) { files.sorted(java.util.Comparator.reverseOrder()).forEach(p -> {try {Files.delete(p);}catch(Exception ignored){}}); }
        }
    }
}
