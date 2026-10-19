#!/usr/bin/env python3
"""Exercise hybrid HEVC on synthetic GPU frames, then decode on the Mac. No phone screen capture."""
import argparse
import json
import os
from pathlib import Path
import struct
import subprocess
import tempfile
import uuid


def run(command, timeout=30):
    return subprocess.run([str(part) for part in command], check=True, capture_output=True, text=True, timeout=timeout).stdout


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--adb', default='/opt/homebrew/bin/adb')
    parser.add_argument('--serial')
    parser.add_argument('--sdk', default=os.environ.get('ANDROID_HOME', str(Path.home() / 'Library/Android/sdk')))
    parser.add_argument('--ffprobe', default='/opt/homebrew/bin/ffprobe')
    args = parser.parse_args()
    root = Path(__file__).resolve().parent.parent
    sdk = Path(args.sdk)
    java = Path(os.environ['JAVA_HOME']) / 'bin' if os.environ.get('JAVA_HOME') else Path('/usr/bin')
    adb = [args.adb]
    if not args.serial:
        devices = [line.split()[0] for line in run(adb + ['devices']).splitlines()
                   if len(line.split()) >= 2 and line.split()[1] == 'device']
        if len(devices) != 1:
            parser.error('Specify --serial unless exactly one authorized phone is connected.')
        args.serial = devices[0]
    adb += ['-s', args.serial]
    remote = f'/data/local/tmp/droidmirror-hevc-{uuid.uuid4().hex}'
    apk = root / 'BluetoothCompanion/build/outputs/apk/debug/DroidMirrorBluetooth-debug.apk'
    production = root / 'BluetoothCompanion/build/intermediates/javac/debug/compileDebugJavaWithJavac/classes'
    with tempfile.TemporaryDirectory(prefix='droidmirror-hevc-') as temporary:
        directory = Path(temporary)
        classes = directory / 'classes'; classes.mkdir()
        dex = directory / 'dex'; dex.mkdir()
        jar = directory / 'production.jar'
        android = sdk / 'platforms/android-36/android.jar'
        run([java / 'jar', 'cf', jar, '-C', production, '.'])
        run([java / 'javac', '-source', '8', '-target', '8', '-cp', f'{android}:{jar}',
             '-d', classes, root / 'Native/HybridHevcPhoneProbe.java'])
        run([sdk / 'build-tools/36.0.0/d8', '--lib', android, '--classpath', jar, '--output', dex,
             *classes.rglob('*.class')])
        try:
            run(adb + ['push', dex / 'classes.dex', remote + '.dex'])
            run(adb + ['push', apk, remote + '.apk'])
            output = run(adb + ['shell', f'CLASSPATH={remote}.dex:{remote}.apk', 'timeout', '25',
                                'app_process', '/system/bin', 'app.droidmirror.bluetooth.HybridHevcPhoneProbe', remote + '.stream'])
            print(output, end='')
            stream = directory / 'probe.stream'
            run(adb + ['pull', remote + '.stream', stream])
        finally:
            subprocess.run(adb + ['shell', 'rm', '-f', remote + '.dex', remote + '.apk', remote + '.stream'],
                           capture_output=True, timeout=10)
        wire = stream.read_bytes()
        assert wire[:4] == b'h265', 'Encoder did not emit HEVC'
        cursor = 4
        sessions = []
        elementary = bytearray()
        configs = 0
        while cursor < len(wire):
            assert len(wire) - cursor >= 12, 'Truncated packet header'
            if wire[cursor] & 0x80:
                flags, width, height = struct.unpack_from('>III', wire, cursor)
                sessions.append((width, height, bool(flags & 1)))
                cursor += 12
                continue
            flags, length = struct.unpack_from('>QI', wire, cursor)
            cursor += 12
            assert 0 < length <= 8 * 1024 * 1024 and cursor + length <= len(wire), 'Invalid packet size'
            configs += bool(flags & (1 << 62))
            elementary.extend(wire[cursor:cursor + length])
            cursor += length
        assert len(sessions) == 7 and configs >= 7, (sessions, configs)
        assert sessions[0][1] <= 1040 and not sessions[0][2], sessions
        assert sessions[1][1] == 1920 and sessions[1][2], sessions
        assert sessions[2][:2] == sessions[0][:2] and sessions[2][2], sessions
        assert sessions[3][1] == 1920 and sessions[3][2], sessions
        assert sessions[4][1] == 1280 and sessions[4][2], sessions
        assert sessions[5][:2] == (1080, 2400) and sessions[5][2], sessions
        assert sessions[6][:2] == sessions[0][:2] and sessions[6][2], sessions
        for width, height, resized in sessions:
            assert width * 2400 == height * 1080, f'Phone aspect ratio changed: {width}x{height}'
        sample = directory / 'synthetic.hevc'; sample.write_bytes(elementary)
        decoded = json.loads(run([args.ffprobe, '-v', 'error', '-select_streams', 'v:0', '-show_frames',
                                  '-show_entries', 'frame=width,height', '-of', 'json', sample]))
        dimensions = {(frame['width'], frame['height']) for frame in decoded['frames']}
        assert dimensions == {(width, height) for width, height, resized in sessions}, dimensions
        print(f'PASS: HEVC decoded at {sorted(dimensions)}; exact phone aspect ratio and window-size preservation across the same-stream reset')


if __name__ == '__main__':
    try:
        main()
    except subprocess.CalledProcessError as error:
        raise SystemExit(error.stdout + error.stderr)
