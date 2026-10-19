#!/usr/bin/env python3
"""Inspect a connected phone's HEVC profiles and vendor controls without capturing video."""
import argparse
import os
from pathlib import Path
import subprocess
import tempfile
import uuid


def run(command):
    return subprocess.run(command, check=True, text=True, capture_output=True, timeout=30).stdout


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--adb', default='/opt/homebrew/bin/adb')
    parser.add_argument('--serial')
    parser.add_argument('--sdk', default=os.environ.get('ANDROID_HOME', str(Path.home() / 'Library/Android/sdk')))
    parser.add_argument('--build-tools', default='36.0.0')
    args = parser.parse_args()
    sdk = Path(args.sdk)
    adb = [args.adb]
    serial = args.serial
    if serial is None:
        devices = [line.split()[0] for line in run(adb + ['devices']).splitlines()
                   if len(line.split()) >= 2 and line.split()[1] == 'device']
        if len(devices) != 1:
            parser.error('Specify --serial when there is not exactly one authorized device.')
        serial = devices[0]
    adb += ['-s', serial]
    java_home = os.environ.get('JAVA_HOME')
    javac = str(Path(java_home) / 'bin/javac') if java_home else 'javac'
    source = Path(__file__).resolve().parents[1] / 'Native/HevcSccPhoneProbe.java'
    remote = f'/data/local/tmp/droidmirror-scc-{uuid.uuid4().hex}.dex'
    with tempfile.TemporaryDirectory(prefix='droidmirror-scc-') as temporary:
        directory = Path(temporary)
        classes = directory / 'classes'; classes.mkdir()
        dex = directory / 'dex'; dex.mkdir()
        run([javac, '-source', '8', '-target', '8', '-cp', str(sdk / 'platforms/android-36/android.jar'),
             '-d', str(classes), str(source)])
        run([str(sdk / 'build-tools' / args.build_tools / 'd8'), '--lib',
             str(sdk / 'platforms/android-36/android.jar'), '--output', str(dex),
             str(classes / 'HevcSccPhoneProbe.class')])
        try:
            run(adb + ['push', str(dex / 'classes.dex'), remote])
            print(run(adb + ['shell', f'CLASSPATH={remote}', 'app_process', '/system/bin', 'HevcSccPhoneProbe']), end='')
        finally:
            subprocess.run(adb + ['shell', 'rm', '-f', remote], check=False, capture_output=True, timeout=10)


if __name__ == '__main__':
    try:
        main()
    except subprocess.CalledProcessError as error:
        raise SystemExit(error.stderr.strip() or f'Codec probe failed with exit code {error.returncode}')
