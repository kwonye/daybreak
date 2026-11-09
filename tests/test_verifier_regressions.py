"""Executable identity regression tests. Temporary bundles and mocked processes only."""
from pathlib import Path
import plistlib
import subprocess
import tempfile
import unittest
from unittest.mock import Mock, patch

from daybreak.models import App
from daybreak.platform import CommandError, Mac, bundle_metadata


class VerifierRegressions(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name).resolve()
        self.bundle = self.root / 'Example.app'
        self.macos = self.bundle / 'Contents/MacOS'
        self.macos.mkdir(parents=True)
        self.primary = self.binary('Example')
        self.write_info()
        self.runner = Mock()
        self.runner.run.return_value = subprocess.CompletedProcess([], 0, '', '')
        self.mac = Mac('/unused-test-bridge', runner=self.runner, launch_timeout=1)
        self.app = App('org.example.App', 'Example', str(self.bundle), '1', '100',
                       (100, 101), launches=(1, 1), executable=str(self.primary))

    def binary(self, name, mode=0o755):
        path = self.macos / name
        path.write_bytes(b'test executable, never executed')
        path.chmod(mode)
        return path

    def write_info(self, executable='Example', **changes):
        info = {'CFBundleIdentifier': 'org.example.App',
                'CFBundleShortVersionString': '2', 'CFBundleVersion': '200'}
        if executable is not None:
            info['CFBundleExecutable'] = executable
        info.update(changes)
        with (self.bundle / 'Contents/Info.plist').open('wb') as handle:
            plistlib.dump(info, handle)

    def row(self, pid=200, executable=None, launched=100):
        return dict(bundle_id=self.app.bundle_id, path=self.app.path, name=self.app.name,
                    pid=pid, executable=str(executable or self.primary), launched=launched)

    def verify(self, rows, target='2', app=None):
        # Exactly one polling iteration, without waiting or invoking a process.
        with patch.object(self.mac, 'current', return_value=rows), \
                patch('daybreak.platform.time.monotonic', side_effect=[0, 0, 2]), \
                patch('daybreak.platform.time.sleep'):
            return self.mac.verify(app or self.app, 100, target)

    def assert_rejected_metadata(self, *observed):
        result = bundle_metadata(self.bundle, observed_executables=observed)
        self.assertEqual(result['executable_source'], 'unresolved')
        self.assertFalse(result['fingerprint'], result)
        self.assertFalse(result['executable'], result)

    def test_docker_new_auxiliary_without_launch_date_does_not_reject_primary(self):
        helper = self.binary('com.docker.backend')
        metadata, pids = self.verify([self.row(), self.row(201, helper, 0)])
        self.assertEqual(metadata['executable'], str(self.primary))
        self.assertIn(200, pids)
        self.runner.checked.assert_not_called()

    def test_original_auxiliary_pid_still_running_rejects_verification(self):
        helper = self.binary('com.docker.backend')
        with self.assertRaises(CommandError):
            self.verify([self.row(), self.row(101, helper, 0)])

    def test_original_primary_pid_still_running_rejects_verification(self):
        with self.assertRaises(CommandError):
            self.verify([self.row(100), self.row(201)])

    def test_only_auxiliary_process_is_not_a_primary(self):
        with self.assertRaises(CommandError):
            self.verify([self.row(201, self.binary('helper'))])

    def test_wrong_primary_start_and_version_fail_closed(self):
        for rows, target in [([self.row(launched=0)], '2'),
                             ([self.row(launched=98)], '2'),
                             ([self.row()], '3')]:
            with self.subTest(rows=rows, target=target), self.assertRaises(CommandError):
                self.verify(rows, target)

    def test_build_number_is_a_valid_update_target(self):
        self.assertEqual(self.verify([self.row()], '200')[0]['build'], '200')

    def test_missing_primary_binary_never_verifies(self):
        self.primary.unlink()
        with self.assertRaises(CommandError):
            self.verify([self.row()])

    def test_muse_missing_or_empty_executable_uses_observed_path(self):
        for field in (None, ''):
            with self.subTest(field=field):
                self.write_info(executable=field)
                metadata = bundle_metadata(self.bundle, observed_executables=(str(self.primary),))
                self.assertEqual(metadata['executable'], str(self.primary))
                self.assertTrue(metadata['fingerprint'])
                self.assertEqual(metadata['executable_source'], 'running-process')
                self.assertEqual(self.verify([self.row()])[0]['executable'], str(self.primary))

    def test_inventory_passes_appkit_observation_into_missing_metadata_fallback(self):
        self.write_info(executable=None)
        with patch.object(self.mac, 'records', return_value=[self.row(100)]):
            apps = self.mac.inventory()
        self.assertEqual(len(apps), 1)
        self.assertEqual(apps[0].executable, str(self.primary))
        self.assertTrue(apps[0].fingerprint)

    def test_fallback_does_not_guess_from_directory_listing(self):
        self.write_info(executable=None)
        self.assert_rejected_metadata()

    def test_ambiguous_observed_executables_are_rejected(self):
        self.write_info(executable=None)
        self.assert_rejected_metadata(str(self.primary), str(self.binary('Other')))

    def test_repeated_observation_of_same_executable_is_unambiguous(self):
        self.write_info(executable=None)
        metadata = bundle_metadata(self.bundle, observed_executables=(str(self.primary), str(self.primary)))
        self.assertEqual(metadata['executable'], str(self.primary))

    def test_external_non_executable_and_directory_fallbacks_are_rejected(self):
        self.write_info(executable=None)
        outside = self.root / 'outside'
        outside.write_bytes(b'outside'); outside.chmod(0o755)
        for path in [outside, self.binary('not-executable', 0o644), self.macos]:
            with self.subTest(path=path):
                self.assert_rejected_metadata(str(path))

    def test_fallback_symlink_cannot_escape_bundle(self):
        self.write_info(executable=None)
        outside = self.root / 'outside'
        outside.write_bytes(b'outside'); outside.chmod(0o755)
        escape = self.macos / 'escape'
        escape.symlink_to(outside)
        self.assert_rejected_metadata(str(escape))

    def test_declared_executable_cannot_escape_bundle(self):
        outside = self.root / 'outside'
        outside.write_bytes(b'outside'); outside.chmod(0o755)
        for field in [str(outside), '../../../outside']:
            with self.subTest(field=field):
                self.write_info(executable=field)
                self.assert_rejected_metadata(str(self.primary))

    def test_declared_missing_executable_is_not_replaced_with_observation(self):
        self.write_info(executable='missing')
        self.assert_rejected_metadata(str(self.primary))

    def test_fallback_verification_is_bound_to_original_snapshot_path(self):
        self.write_info(executable=None)
        other = self.binary('Other')
        with self.assertRaises(CommandError):
            self.verify([self.row(executable=other)])

    def test_declared_metadata_does_not_fallback_for_malformed_values(self):
        for field in ['../Example', '.', '..', 7, ['Example']]:
            with self.subTest(field=field):
                self.write_info(executable=field)
                self.assert_rejected_metadata(str(self.primary))

    def test_codesign_detritus_failure_does_not_strip_metadata_or_retry(self):
        self.runner.run.return_value = subprocess.CompletedProcess(
            [], 1, '', 'resource fork, Finder information, or similar detritus not allowed')
        with self.assertRaises(CommandError):
            self.mac.signer(self.app)
        self.runner.run.assert_called_once_with(
            ['/usr/bin/codesign', '--verify', '--deep', '--strict', self.app.path], 120)
        self.runner.checked.assert_not_called()

    def test_signature_and_bundle_identity_checks_remain_required(self):
        with patch.object(self.mac, 'signer', return_value='OTHER'):
            with self.assertRaises(CommandError):
                self.mac.check_signature(self.app, 'TEAM')
        self.write_info(CFBundleIdentifier='org.example.Unexpected')
        with patch.object(self.mac, 'signer', return_value='TEAM'):
            with self.assertRaises(CommandError):
                self.mac.check_signature(self.app, 'TEAM')


if __name__ == '__main__':
    unittest.main()
