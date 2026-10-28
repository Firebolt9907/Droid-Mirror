#!/usr/bin/env python3
"""Install matching development APKs on the connected phone and Wear OS watches."""
import argparse
import os
from pathlib import Path
import subprocess
import sys

ROOT = Path(__file__).resolve().parent.parent


def run(command, *, capture=False, cwd=None):
    return subprocess.run([str(value) for value in command], check=True, cwd=cwd,
                          text=True, stdout=subprocess.PIPE if capture else None,
                          stderr=subprocess.STDOUT if capture else None)


def select_devices(adb, env):
    devices = []
    for line in run([adb, 'devices'], capture=True).stdout.splitlines()[1:]:
        fields = line.split()
        if len(fields) >= 2 and fields[1] == 'device':
            devices.append(fields[0])
    phones, watches = [], []
    for serial in devices:
        try:
            features = run([adb, '-s', serial, 'shell', 'pm', 'list', 'features'], capture=True).stdout
            if not any(line.startswith('feature:') for line in features.splitlines()):
                raise RuntimeError('device returned no feature list')
        except (subprocess.CalledProcessError, RuntimeError) as error:
            print(f'Skipping Android device {serial}: could not identify its type ({error}).', flush=True)
            continue
        target = watches if 'feature:android.hardware.type.watch' in features.splitlines() else phones
        target.append(serial)

    phone = env.get('ANDROID_SERIAL', '')
    if phone and phone not in phones:
        raise RuntimeError(f'Phone {phone} is unavailable, unauthorized or not a phone. '
                           'Use DROIDMIRROR_WATCH_SERIAL to select a watch.')
    if not phone and len(phones) > 1:
        raise RuntimeError('Multiple Android phones connected; set ANDROID_SERIAL.')
    phone = phone or (phones[0] if phones else None)
    watch = env.get('DROIDMIRROR_WATCH_SERIAL', '')
    if env.get('DROIDMIRROR_SKIP_WATCH_INSTALL') == '1':
        watches = []
    elif watch:
        if watch not in watches:
            raise RuntimeError(f'Watch {watch} is unavailable, unauthorized or not a Wear OS watch.')
        watches = [watch]
    return phone, watches


def install_phone(adb, serial):
    run(['./gradlew', '--no-daemon', ':assembleDebug'], cwd=ROOT / 'BluetoothCompanion')
    run([adb, '-s', serial, 'install', '-r',
         ROOT / 'BluetoothCompanion/build/outputs/apk/debug/DroidMirrorBluetooth-debug.apk'])
    command = [adb, '-s', serial, 'shell', 'am']
    action = 'app.droidmirror.bluetooth.action.START_READY'
    result = run([*command, 'start', '-W', '-a', action, '-n',
                  'app.droidmirror.bluetooth/.SilentStartActivity', '-f', '0x10000000'], capture=True).stdout
    print(result, end='' if result.endswith('\n') else '\n', flush=True)
    if 'Error:' in result or 'Status: timeout' in result:
        raise RuntimeError('Android bridge startup failed.')
    run([*command, 'broadcast', '-a', action, '-n',
         'app.droidmirror.bluetooth/.AutomationReceiver', '-f', '0x20'])
    print('Bridge startup requested. If NOT_CONFIGURED or PERMISSION_REQUIRED appears, '
          'complete setup in the Android app.', flush=True)


def install_watches(adb, watches):
    if not watches:
        print('Skipping watch install: no selected, authorized Wear OS watch connected.', flush=True)
        return
    try:
        run(['./gradlew', '--no-daemon', ':wear:assembleDebug'], cwd=ROOT / 'BluetoothCompanion')
    except subprocess.CalledProcessError as error:
        print(f'Warning: could not build the optional watch app ({error}); continuing Mac update.', file=sys.stderr)
        return
    for serial in watches:
        try:
            run([adb, '-s', serial, 'install', '-r',
                 ROOT / 'BluetoothCompanion/wear/build/outputs/apk/debug/wear-debug.apk'])
            print(f'Updated Wear OS app on {serial}. Open DroidMirror on the watch and allow notifications.', flush=True)
        except subprocess.CalledProcessError as error:
            print(f'Warning: watch install failed on {serial} ({error}); continuing Mac update.', file=sys.stderr)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--adb', required=True)
    args = parser.parse_args()
    phone, watches = select_devices(args.adb, os.environ)
    if phone:
        install_phone(args.adb, phone)
    else:
        print('Skipping phone install: no authorized phone connected.', flush=True)
    install_watches(args.adb, watches)


if __name__ == '__main__':
    try:
        main()
    except (OSError, RuntimeError, subprocess.CalledProcessError) as error:
        sys.exit(f'Android install failed: {error}')
