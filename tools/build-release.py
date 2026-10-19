#!/usr/bin/env python3
"""Build and install matching macOS and Android release apps on this Mac and phone."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import platform
import re
import shutil
import subprocess
import sys
import tempfile

ROOT = Path(__file__).resolve().parent.parent


def run(command, *, capture=False, env=None, cwd=ROOT):
    return subprocess.run([str(arg) for arg in command], check=True, cwd=cwd,
                          env=env, text=True, stdout=subprocess.PIPE if capture else None,
                          stderr=subprocess.STDOUT if capture else None)


def stop_mac_for_update(env):
    print('Ending active Mac mirror sessions before updating…', flush=True)
    # Use the normal quit path so phone display/input cleanup finishes first.
    # Do not launch the app if it is already closed, or force-kill a stuck session.
    run(['/usr/bin/osascript', '-e', '''
if application id "app.droidmirror.mac" is running then
    try
        tell application id "app.droidmirror.mac" to quit
    end try
    repeat 120 times
        if application id "app.droidmirror.mac" is not running then return
        delay 0.25
    end repeat
    error "DroidMirror did not quit; stop mirroring and retry the installation."
end if
'''], env=env)


def start_android_bridge(adb, serial, env):
    print('Resuming Android background bridge…', flush=True)
    command = [adb, '-s', serial, 'shell', 'am']
    action = 'app.droidmirror.bluetooth.action.START_READY'
    # The foreground entry avoids Android's background-service startup restriction.
    result = run([*command, 'start', '-W', '-a', action, '-n',
                  'app.droidmirror.bluetooth/.SilentStartActivity', '-f', '0x10000000'],
                 capture=True, env=env).stdout
    if 'Error:' in result or 'Status: timeout' in result:
        raise RuntimeError(f'Android bridge activity failed: {result.strip()}')
    # The ordered receiver reports whether saved setup permits a startup request.
    result = run([*command, 'broadcast', '-a', action, '-n',
                  'app.droidmirror.bluetooth/.AutomationReceiver', '-f', '0x20'],
                 capture=True, env=env).stdout
    if re.search(r'Broadcast completed: result=-1, data="START_REQUESTED"', result):
        print('Android bridge startup requested (Bluetooth/Shizuku readiness still required).', flush=True)
    else:
        print(f'Android bridge needs attention: {result.strip()}\n'
              'Open DroidMirror on the phone, complete setup and enable the background bridge.',
              flush=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--build-only', action='store_true', help='Build without installing either app')
    parser.add_argument('--device', help='ADB serial (required if multiple devices are connected)')
    parser.add_argument('--mac-destination', type=Path, default=Path('/Applications/DroidMirror.app'))
    args = parser.parse_args()
    if platform.system() != 'Darwin':
        parser.error('Run this script on the Mac that will receive DroidMirror')
    env = os.environ.copy()
    env['ANDROID_HOME'] = env.get('ANDROID_HOME', str(Path.home() / 'Library/Android/sdk'))
    if not env.get('JAVA_HOME'):
        env['JAVA_HOME'] = run(['/usr/libexec/java_home', '-v', '21'], capture=True).stdout.strip()
    env['PATH'] = f"{env['JAVA_HOME']}/bin:{env['ANDROID_HOME']}/platform-tools:{env.get('PATH', '')}"
    for tool in ('java', 'cargo', 'swift', 'xcrun', 'meson', 'ninja', 'pkg-config'):
        if not shutil.which(tool, path=env['PATH']):
            parser.error(f'Missing required tool: {tool}')
    sdk_tools = Path(env['ANDROID_HOME']) / 'build-tools'
    versions = sorted((p for p in sdk_tools.glob('*') if re.fullmatch(r'\d+(\.\d+)+', p.name)),
                      key=lambda p: tuple(map(int, p.name.split('.'))))
    if not versions:
        parser.error('Install Android SDK build-tools 36+')
    apksigner, zipalign = (versions[-1] / name for name in ('apksigner', 'zipalign'))
    for tool in (apksigner, zipalign):
        if not tool.is_file():
            parser.error(f'Missing required tool: {tool}')

    # Preserve the phone's installed identity by default; compilation is still release.
    keystore = Path(env.get('DROIDMIRROR_ANDROID_KEYSTORE', str(Path.home() / '.android/debug.keystore'))).expanduser()
    if not keystore.is_file():
        parser.error(f'Signing keystore is missing: {keystore}')
    if 'DROIDMIRROR_ANDROID_KEYSTORE' in env:
        for name in ('DROIDMIRROR_ANDROID_KEY_ALIAS', 'DROIDMIRROR_ANDROID_STORE_PASSWORD', 'DROIDMIRROR_ANDROID_KEY_PASSWORD'):
            if not env.get(name):
                parser.error(f'Set {name} when using a custom keystore')
    else:
        env.setdefault('DROIDMIRROR_ANDROID_KEY_ALIAS', 'androiddebugkey')
        env.setdefault('DROIDMIRROR_ANDROID_STORE_PASSWORD', 'android')
        env.setdefault('DROIDMIRROR_ANDROID_KEY_PASSWORD', 'android')

    adb = shutil.which('adb', path=env['PATH'])
    serial = args.device or env.get('ANDROID_SERIAL')
    if not args.build_only:
        if not adb:
            parser.error('Install Android platform-tools (adb)')
        entries = [line.split() for line in run([adb, 'devices'], capture=True, env=env).stdout.splitlines()[1:] if line.strip()]
        ready = [entry[0] for entry in entries if len(entry) > 1 and entry[1] == 'device']
        if serial and serial not in ready:
            parser.error(f'Android device {serial} is unavailable or unauthorized')
        if not serial:
            if len(ready) != 1:
                parser.error('Connect and authorize exactly one Android device, or pass --device SERIAL')
            serial = ready[0]
        destination = args.mac_destination.expanduser().absolute()
        if destination.suffix != '.app' or destination.is_symlink():
            parser.error('--mac-destination must be a non-symlink .app path')
        if not destination.parent.is_dir() or not os.access(destination.parent, os.W_OK):
            parser.error(f'Mac install directory is not writable: {destination.parent}')

    print('Building Android release…', flush=True)
    run(['./gradlew', '--no-daemon', 'assembleRelease'], cwd=ROOT / 'BluetoothCompanion', env=env)
    release_dir = ROOT / 'BluetoothCompanion/build/outputs/apk/release'
    metadata = json.loads((release_dir / 'output-metadata.json').read_text())
    if len(metadata['elements']) != 1:
        raise RuntimeError('Expected one universal release APK, but Gradle produced split APKs')
    unsigned = release_dir / metadata['elements'][0]['outputFile']
    if not unsigned.is_file():
        raise RuntimeError(f'Expected unsigned release APK: {unsigned}')
    outputs = ROOT / 'outputs'
    outputs.mkdir(exist_ok=True)
    apk = outputs / 'DroidMirror-Bluetooth-release.apk'
    with tempfile.TemporaryDirectory(prefix='.android-release-', dir=outputs) as staging:
        aligned, signed = (Path(staging) / name for name in ('aligned.apk', 'signed.apk'))
        run([zipalign, '-P', '16', '-f', '4', unsigned, aligned], env=env)
        run([apksigner, 'sign', '--ks', keystore, '--ks-key-alias', env['DROIDMIRROR_ANDROID_KEY_ALIAS'],
             '--ks-pass', 'env:DROIDMIRROR_ANDROID_STORE_PASSWORD',
             '--key-pass', 'env:DROIDMIRROR_ANDROID_KEY_PASSWORD', '--out', signed, aligned], env=env)
        run([apksigner, 'verify', '--verbose', signed], env=env)
        run([zipalign, '-c', '-P', '16', '4', signed], env=env)
        signed.replace(apk)
    apk.with_suffix('.apk.sha256').write_text(f'{hashlib.sha256(apk.read_bytes()).hexdigest()}  {apk.name}\n')

    print('Building macOS release…', flush=True)
    env['DROIDMIRROR_BUILD_CONFIGURATION'] = 'release'
    env['DROIDMIRROR_SKIP_ANDROID_INSTALL'] = '1'
    env['DROIDMIRROR_SKIP_MAC_INSTALL'] = '1'  # The release workflow installs after both builds pass.
    run(['/bin/zsh', ROOT / 'build-app.sh'], env=env)
    app = outputs / 'DroidMirror.app'
    print(f'Release artifacts: {app}\n{apk}', flush=True)
    if args.build_only:
        return
    stop_mac_for_update(env)
    print(f'Installing Android release on {serial}…', flush=True)
    # Never uninstall or allow a downgrade: retain pairing, Shizuku grants and data.
    run([adb, '-s', serial, 'install', '-r', apk], env=env)
    print(f'Android installed. Installing macOS release at {destination}…', flush=True)
    run([sys.executable, ROOT / 'tools/app-bundle.py', 'install', app, destination], env=env)
    start_android_bridge(adb, serial, env)
    print(f'Installed both release builds: {destination} and Android {serial}', flush=True)


if __name__ == '__main__':
    try:
        main()
    except (subprocess.CalledProcessError, OSError, RuntimeError) as error:
        sys.exit(f'Release build/install failed: {error}')
