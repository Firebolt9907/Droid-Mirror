#!/usr/bin/env python3
"""Ten-second Classic L2CAP receive benchmarks; no screen capture or saved payloads."""
import argparse
from pathlib import Path
import re
import select
import shlex
import subprocess
import time
import xml.etree.ElementTree as ET

ROOT = Path(__file__).resolve().parents[1]
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('phone', help='Paired phone Classic address, as shown by helper --list')
parser.add_argument('--adb', default=str(Path.home() / 'Library/Android/sdk/platform-tools/adb'))
parser.add_argument('--helper', default=str(ROOT / 'outputs/DroidMirror.app/Contents/Helpers/DroidMirrorBluetooth'))
args = parser.parse_args()

def adb(*command):
    return subprocess.check_output([args.adb, *command], text=True).strip()

apk = adb('shell', 'pm', 'path', 'app.droidmirror.bluetooth').removeprefix('package:')
settings = ET.fromstring(adb('shell', 'run-as', 'app.droidmirror.bluetooth', 'cat', 'shared_prefs/ready.xml'))
mac = next(item.text for item in settings if item.get('name') == 'peer')
for size, mode in [(672, 'direct'), (256, 'direct'), (672, 'pipe')]:
    command = 'CLASSPATH=' + shlex.quote(apk) + ' ' + shlex.join([
        'app_process', '/system/bin', 'app.droidmirror.bluetooth.ClassicL2capBenchmark', mac, str(size), mode])
    sender = subprocess.Popen([args.adb, 'shell', command], stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
    logs = []
    try:
        deadline = time.monotonic() + 25
        while time.monotonic() < deadline:
            readable, _, _ = select.select([sender.stdout], [], [], 1)
            if not readable:
                continue
            line = sender.stdout.readline()
            if not line:
                raise RuntimeError('Benchmark sender exited before listening: ' + ''.join(logs)[-2000:])
            logs.append(line)
            if 'BENCH READY' in line:
                break
        else:
            raise TimeoutError('Benchmark sender did not start')
        receiver = subprocess.run([args.helper, '--benchmark', args.phone], capture_output=True, text=True, timeout=35)
        remaining, _ = sender.communicate(timeout=10)
        logs.append(remaining)
        print(f'\n{mode}, generator writes {size} bytes')
        for line in ''.join(logs).splitlines():
            if line.startswith('BENCH '):
                print(line)
        print(receiver.stdout.strip())
        if sender.returncode or receiver.returncode:
            raise RuntimeError('Benchmark failed: ' + receiver.stderr[-1500:] + ''.join(logs)[-2000:])
        sent = re.search(r'BENCH SENT bytes=(\d+)', ''.join(logs))
        received = re.search(r'BENCH RECEIVED bytes=(\d+)', receiver.stdout)
        if not sent or not received or sent.group(1) != received.group(1):
            raise RuntimeError('Sent and received totals differ; do not treat this sample as valid')
    finally:
        if sender.poll() is None:
            sender.terminate()
            try:
                sender.wait(timeout=3)
            except subprocess.TimeoutExpired:
                sender.kill()
