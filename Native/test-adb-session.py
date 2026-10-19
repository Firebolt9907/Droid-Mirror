#!/usr/bin/env python3
"""On-device ADB session check. Requires the rebuilt companion installed on a test phone.

Captures the phone to a temporary recording, tests notification controls and a
synthetic hardware Power press, then removes the recording. Leaves keyguard awake.
"""
import argparse
import os
from pathlib import Path
import re
import subprocess
import tempfile
import time

ROOT = Path(__file__).resolve().parent.parent
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--adb', default='/opt/homebrew/bin/adb')
parser.add_argument('--server', required=True)
parser.add_argument('--client', default=str(ROOT / 'scrcpy-5.0/build/app/scrcpy'))
parser.add_argument('--serial')
parser.add_argument('--scenario', choices=['all', 'disconnect', 'notification', 'power'], default='all')
args = parser.parse_args()
adb = [args.adb] + (['-s', args.serial] if args.serial else [])


def shell(*words):
    return subprocess.check_output(adb + ['shell', *words], text=True, timeout=10)


def service():
    return shell('dumpsys', 'activity', 'services', 'app.droidmirror.bluetooth/.AdbStreamService')


def until(predicate, timeout=15):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        result = predicate()
        if result:
            return result
        time.sleep(.1)
    raise AssertionError('Timed out waiting for ADB session state')


with tempfile.TemporaryDirectory(prefix='droidmirror-adb-test-') as directory:
    for scenario in (['disconnect', 'notification', 'power'] if args.scenario == 'all' else [args.scenario]):
        log_path = Path(directory) / f'{scenario}.log'
        with log_path.open('w') as log:
            env = dict(os.environ, ADB=args.adb, DROIDMIRROR_TRANSPORT='adb',
                       SCRCPY_SERVER_PATH=str(Path(args.server).resolve()))
            command = [args.client, '--no-audio', '--no-playback', '--turn-screen-off',
                       '--power-off-on-close', '--max-size=480', '--max-fps=5',
                       f'--record={directory}/{scenario}.mkv']
            if scenario == 'disconnect':
                command.append('--time-limit=4')
            if args.serial:
                command.append(f'--serial={args.serial}')
            process = subprocess.Popen(command, env=env, stdout=log, stderr=log)
            try:
                until(lambda: 'PROMOTED_ONGOING' in service())
                # Exercise the physically-off panel, after the client's startup command.
                until(lambda: 'Device display turned off' in log_path.read_text())
                if scenario == 'disconnect':
                    pass  # The client's own time limit exercises orderly shutdown.
                elif scenario == 'notification':
                    intents = shell('dumpsys', 'activity', 'intents')
                    token = re.search(r'droidmirror://stream/(adb-[\w-]+)', intents).group(1)
                    # A stale notification must not terminate the active session.
                    shell('am', 'startservice', '-n', 'app.droidmirror.bluetooth/.AdbStreamService',
                          '-a', 'app.droidmirror.bluetooth.action.DISCONNECT_STREAM', '--es', 'session', 'adb-stale')
                    assert process.poll() is None
                    shell('am', 'startservice', '-n', 'app.droidmirror.bluetooth/.AdbStreamService',
                          '-a', 'app.droidmirror.bluetooth.action.DISCONNECT_STREAM', '--es', 'session', token)
                else:
                    started = time.monotonic()
                    shell('input', 'keyevent', 'KEYCODE_POWER')
                process.wait(timeout=8)
                until(lambda: 'isForeground=true' not in service(), timeout=5)
                output = log_path.read_text()
                if scenario == 'power':
                    assert 'DROIDMIRROR_LOCAL_USE' in output, output
                    assert 'mWakefulness=Awake' in shell('dumpsys', 'power')
                    assert 'showing=true' in shell('dumpsys', 'window', 'policy')
                    print(f'PASS: Power ends stream, removes Live Activity, and restores awake keyguard ({time.monotonic() - started:.2f}s including ADB checks)')
                else:
                    assert 'DROIDMIRROR_LOCAL_USE' not in output, output
                    print(f'PASS: {scenario} stops stream and removes Live Activity')
            except Exception:
                print(log_path.read_text(), flush=True)
                raise
            finally:
                if process.poll() is None:
                    process.terminate()
                    try:
                        process.wait(timeout=5)
                    except subprocess.TimeoutExpired:
                        process.kill()
                        process.wait(timeout=5)
