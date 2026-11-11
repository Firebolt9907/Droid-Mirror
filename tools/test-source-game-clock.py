#!/usr/bin/env python3
"""Exercise the actual Android source-clock widget without installing/restarting the app."""
import glob
import os
from pathlib import Path
import subprocess
import tempfile
import zipfile

ROOT = Path(__file__).resolve().parents[1]
SDK = Path(os.environ.get("ANDROID_HOME", str(Path.home() / "Library/Android/sdk")))
JAVA = Path(os.environ.get("JAVA_HOME", "/Library/Java/JavaVirtualMachines/temurin-21.jdk/Contents/Home")) / "bin"
ADB = str(SDK / "platform-tools/adb")


def main():
    devices = subprocess.run([ADB, "devices"], check=True, text=True, capture_output=True).stdout.splitlines()[1:]
    ready = [line.split()[0] for line in devices if len(line.split()) == 2 and line.split()[1] == "device"]
    if len(ready) != 1:
        raise SystemExit("Connect exactly one authorized Android device; no APK will be installed or service restarted.")
    adb = [ADB, "-s", ready[0]]
    cache = Path(os.environ.get("GRADLE_USER_HOME", str(Path.home() / ".gradle")))
    stdlib = Path(glob.glob(str(cache / "caches/modules-2/files-2.1/org.jetbrains.kotlin/kotlin-stdlib/2.3.20/*/*.jar"))[0])
    classes = ROOT / "BluetoothCompanion/build/tmp/kotlin-classes/debug"
    source = classes / "app/droidmirror/bluetooth/bridge"
    if not (source / "ActivitySourceGameClock.class").exists():
        raise SystemExit("Run the Android compileDebugKotlin task first.")
    android = SDK / "platforms/android-36/android.jar"
    with tempfile.TemporaryDirectory(prefix="droidmirror-source-clock-") as temporary:
        work = Path(temporary)
        subprocess.run([str(JAVA / "javac"), "--release", "17", "-cp", os.pathsep.join(map(str, [android, stdlib, classes])),
                        "-d", str(work), str(ROOT / "BluetoothCompanion/tests/ActivitySourceGameClockDeviceTest.java")], check=True)
        jar = work / "source-clock.jar"
        with zipfile.ZipFile(jar, "w") as out:
            with zipfile.ZipFile(stdlib) as lib:
                for entry in lib.infolist():
                    if entry.filename.endswith(".class"):
                        out.writestr(entry.filename, lib.read(entry))
            for path in source.glob("ActivitySourceGameClock*.class"):
                out.write(path, str(path.relative_to(classes)))
            for path in work.glob("ActivitySourceGameClockDeviceTest*.class"):
                out.write(path, path.name)
        dex = work / "dex"
        dex.mkdir()
        compiler = subprocess.run([str(JAVA / "java"), "-cp", str(SDK / "build-tools/36.1.0/lib/d8.jar"),
                                   "com.android.tools.r8.D8", "--min-api", "26", "--lib", str(android),
                                   "--output", str(dex), str(jar)], text=True, capture_output=True)
        if compiler.returncode:
            raise SystemExit("\n".join(compiler.stderr.splitlines()[-30:]))
        remote = "/data/local/tmp/droidmirror-source-clock-test.dex"
        try:
            subprocess.run(adb + ["push", str(dex / "classes.dex"), remote], check=True)
            subprocess.run(adb + ["shell", "CLASSPATH=" + remote, "app_process", "/system/bin",
                                  "ActivitySourceGameClockDeviceTest"], check=True, timeout=20)
        finally:
            subprocess.run(adb + ["shell", "rm", "-f", remote], check=False)


if __name__ == "__main__":
    main()
