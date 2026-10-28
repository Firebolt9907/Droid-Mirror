#!/usr/bin/env python3
import importlib.util
import subprocess
import unittest
from unittest.mock import patch

spec = importlib.util.spec_from_file_location('installer', __file__.replace('test-install-', 'install-'))
installer = importlib.util.module_from_spec(spec)
spec.loader.exec_module(installer)


class AndroidInstallTests(unittest.TestCase):
    def discover(self, entries, features, env=None):
        def run(command, **kwargs):
            if command == ['adb', 'devices']:
                return subprocess.CompletedProcess(command, 0, 'List of devices attached\n' + entries)
            serial = command[2]
            value = features[serial]
            if isinstance(value, Exception):
                raise value
            return subprocess.CompletedProcess(command, 0, value)
        with patch.object(installer, 'run', side_effect=run):
            return installer.select_devices('adb', env or {})

    def test_phone_and_watch_are_selected_separately(self):
        self.assertEqual(self.discover('phone device\nwatch device\n', {
            'phone': 'feature:android.hardware.telephony\n',
            'watch': 'feature:android.hardware.type.watch\n'}), ('phone', ['watch']))

    def test_watch_only_never_receives_phone_app(self):
        self.assertEqual(self.discover('watch device\n', {
            'watch': 'feature:android.hardware.type.watch\n'}), (None, ['watch']))

    def test_unauthorized_and_unidentifiable_devices_are_skipped(self):
        self.assertEqual(self.discover('watch unauthorized\nbad device\n', {
            'bad': 'Error: device unavailable\n'}), (None, []))

    def test_multiple_watches_and_selection(self):
        features = {'w1': 'feature:android.hardware.type.watch\n', 'w2': 'feature:android.hardware.type.watch\n'}
        self.assertEqual(self.discover('w1 device\nw2 device\n', features), (None, ['w1', 'w2']))
        self.assertEqual(self.discover('w1 device\nw2 device\n', features,
                                       {'DROIDMIRROR_WATCH_SERIAL': 'w2'}), (None, ['w2']))
        self.assertEqual(self.discover('w1 device\nw2 device\n', features,
                                       {'DROIDMIRROR_SKIP_WATCH_INSTALL': '1'}), (None, []))

    def test_wrong_explicit_target_fails_before_install(self):
        with self.assertRaises(RuntimeError):
            self.discover('watch device\n', {'watch': 'feature:android.hardware.type.watch\n'}, {'ANDROID_SERIAL': 'watch'})
        with self.assertRaises(RuntimeError):
            self.discover('phone device\n', {'phone': 'feature:android.hardware.telephony\n'}, {'DROIDMIRROR_WATCH_SERIAL': 'phone'})

    def test_multiple_phones_still_require_selection(self):
        features = {'p1': 'feature:android.hardware.telephony\n', 'p2': 'feature:android.hardware.telephony\n'}
        with self.assertRaises(RuntimeError):
            self.discover('p1 device\np2 device\n', features)
        self.assertEqual(self.discover('p1 device\np2 device\n', features, {'ANDROID_SERIAL': 'p2'}), ('p2', []))

    def test_failed_watch_install_does_not_block_other_watches(self):
        calls = []
        def run(command, **kwargs):
            calls.append(command)
            if command[:4] == ['adb', '-s', 'w1', 'install']:
                raise subprocess.CalledProcessError(1, command)
        with patch.object(installer, 'run', side_effect=run):
            installer.install_watches('adb', ['w1', 'w2'])
        self.assertEqual(calls[0], ['./gradlew', '--no-daemon', ':wear:assembleDebug'])
        self.assertEqual([cmd[2] for cmd in calls[1:]], ['w1', 'w2'])
        self.assertTrue(all(str(cmd[-1]).endswith('/wear-debug.apk') for cmd in calls[1:]))
        self.assertTrue(all(cmd[3:5] == ['install', '-r'] for cmd in calls[1:]))

    def test_phone_install_uses_only_phone_task_and_restarts_bridge(self):
        with patch.object(installer, 'run', return_value=subprocess.CompletedProcess([], 0, 'Status: ok\n')) as run:
            installer.install_phone('adb', 'phone')
        calls = [call.args[0] for call in run.call_args_list]
        self.assertEqual(calls[0], ['./gradlew', '--no-daemon', ':assembleDebug'])
        self.assertEqual(calls[1][0:5], ['adb', '-s', 'phone', 'install', '-r'])
        self.assertIn('.SilentStartActivity', calls[2][calls[2].index('-n') + 1])
        self.assertEqual(calls[3][4:6], ['am', 'broadcast'])


if __name__ == '__main__':
    unittest.main()
