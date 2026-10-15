#!/usr/bin/env python3
"""One-time developer provisioning over an already authorized ADB connection; prints no secrets."""
import argparse
from pathlib import Path
import base64
import subprocess
import xml.etree.ElementTree as ET

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('phone', help='Selected Classic phone address')
parser.add_argument('--adb', default=str(Path.home() / 'Library/Android/sdk/platform-tools/adb'))
parser.add_argument('--helper', default=str(Path(__file__).resolve().parents[1] / 'outputs/DroidMirror.app/Contents/Helpers/DroidMirrorBluetooth'))
args = parser.parse_args()

def adb(*command):
    return subprocess.check_output([args.adb, *command], timeout=15)

adb('shell', 'am', 'start', '-W', '-a', 'app.droidmirror.bluetooth.action.START_READY', '-n', 'app.droidmirror.bluetooth/.SilentStartActivity')
settings = ET.fromstring(adb('shell', 'run-as', 'app.droidmirror.bluetooth', 'cat', 'shared_prefs/ready.xml'))
mac = next(item.text for item in settings if item.get('name') == 'peer')
store = ET.fromstring(adb('shell', 'run-as', 'app.droidmirror.bluetooth', 'cat', 'shared_prefs/ble_pairing.xml'))
key = base64.b64decode(next(item.text for item in store if item.get('name') == mac), validate=True)
if len(key) != 32:
    raise ValueError('Invalid pairing code length')
subprocess.run([args.helper, '--pair', args.phone], input=key, check=True, timeout=60)
print('BLE pairing provisioned in the helper Keychain. No key was logged or written to a local file.')
