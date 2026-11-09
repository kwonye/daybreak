"""Coordinator safety tests. All application operations are mocked."""
from dataclasses import replace
import unittest
from unittest.mock import Mock

from daybreak.coordinator import Coordinator
from daybreak.models import App, Check, InstallResult
from daybreak.platform import CommandError, Mac


class CoordinatorTests(unittest.TestCase):
    def setUp(self):
        self.app = App('org.example.Editor', 'Editor', '/Applications/Editor.app',
                       '1.0', '100', (1001,), fingerprint='old')
        self.mac = Mock(spec=Mac)
        self.backend = Mock(spec=['name', 'manages_lifecycle', 'check', 'apply'])
        self.backend.name = 'test-updater'
        self.backend.manages_lifecycle = False
        self.backend.check.return_value = Check('available', '2.0')
        self.registry = Mock()
        self.registry.for_app.return_value = self.backend
        self.mac.current.side_effect = [[{'pid': 1001}], [], []]
        self.mac.quit.return_value = True
        self.mac.signer.return_value = 'TEAM'
        self.mac.verify.return_value = ({'version': '2.0', 'build': '200', 'fingerprint': 'new'}, [2002])

    def handle(self, config=None, app=None, apply=True):
        return Coordinator(self.mac, self.registry, config or {}).handle(app or self.app, apply)

    def test_dry_run_calls_no_mac_or_updater_operations(self):
        result = self.handle(apply=False)
        self.assertEqual(result.status, 'planned')
        self.assertEqual(self.mac.mock_calls, [])
        self.backend.check.assert_not_called()
        self.backend.apply.assert_not_called()

    def test_protected_apps_never_reach_registry_or_mac(self):
        for app in [replace(self.app, bundle_id='com.openai.codex'),
                    replace(self.app, bundle_id='com.openai.chat'),
                    replace(self.app, path='/System/Applications/Editor.app'),
                    replace(self.app, path='/Library/Apple/Editor.app'),
                    replace(self.app, path='/usr/Editor.app'),
                    replace(self.app, path='/Applications/Outer.app/Contents/Editor.app')]:
            for apply in [True, False]:
                with self.subTest(app=app, apply=apply):
                    self.assertEqual(self.handle(app=app, apply=apply).status, 'excluded')
        self.registry.for_app.assert_not_called()
        self.assertEqual(self.mac.mock_calls, [])

    def test_explicit_exclusion_never_selects_backend(self):
        self.assertEqual(self.handle({'exclude': [self.app.bundle_id]}).status, 'excluded')
        self.registry.for_app.assert_not_called()

    def test_docker_without_workload_opt_in_is_blocked_even_restart_only(self):
        app = replace(self.app, bundle_id='com.docker.docker')
        self.assertEqual(self.handle(app=app).status, 'blocked')
        self.registry.for_app.assert_not_called()
        self.assertEqual(self.mac.mock_calls, [])

    def test_app_that_stopped_since_inventory_is_not_reopened(self):
        self.mac.current.side_effect = None
        self.mac.current.return_value = []
        self.assertEqual(self.handle().status, 'skipped')
        self.backend.check.assert_not_called()
        self.mac.relaunch.assert_not_called()

    def test_save_prompt_refusal_prevents_install_and_relaunch(self):
        self.mac.quit.return_value = False
        self.assertEqual(self.handle().status, 'deferred')
        self.backend.apply.assert_not_called()
        self.mac.relaunch.assert_not_called()
        self.mac.verify.assert_not_called()

    def test_success_reports_installed_version_and_fresh_pid(self):
        result = self.handle()
        self.assertEqual(result.status, 'updated_and_relaunched')
        self.assertEqual((result.before, result.after), ('1.0', '2.0'))
        self.assertEqual((result.old_pids, result.new_pids), ([1001], [2002]))
        self.backend.apply.assert_called_once_with(self.app)
        self.mac.check_signature.assert_called_once_with(self.app, 'TEAM')
        self.mac.relaunch.assert_called_once_with(self.app)
        self.assertEqual(self.mac.verify.call_args.args[2], '2.0')

    def test_sparkle_no_update_still_verifies_signature_and_relaunch(self):
        self.backend.check.return_value = Check('available')
        self.backend.apply.return_value = InstallResult('no_update', 'Sparkle reported no update at install time')
        self.mac.verify.return_value = ({'version': '1.0', 'build': '100', 'fingerprint': 'old'}, [2002])
        result = self.handle()
        self.assertEqual(result.status, 'checked_and_relaunched')
        self.assertEqual(result.update_outcome, 'no_update')
        self.assertEqual((result.before_build, result.after_build), ('100', '100'))
        self.assertIn('no upgrade claimed', result.detail)
        self.mac.check_signature.assert_called_once_with(self.app, 'TEAM')
        self.mac.relaunch.assert_called_once_with(self.app)
        self.mac.verify.assert_called_once()

    def test_no_update_does_not_claim_installer_upgraded_changed_bundle(self):
        self.backend.apply.return_value = InstallResult('no_update', 'No update')
        result = self.handle()
        self.assertEqual(result.status, 'checked_and_relaunched')
        self.assertEqual(result.after, '2.0')

    def test_no_update_never_ignores_signature_failure(self):
        self.backend.apply.return_value = InstallResult('no_update', 'No update')
        self.mac.check_signature.side_effect = CommandError('Signature invalid')
        self.mac.current.side_effect = [[{'pid': 1001}], []]
        result = self.handle()
        self.assertEqual(result.status, 'failed')
        self.mac.relaunch.assert_not_called()

    def test_install_failure_attempts_safe_reopen(self):
        self.backend.apply.side_effect = CommandError('installer failed')
        self.mac.current.side_effect = [[{'pid': 1001}], []]
        result = self.handle()
        self.assertEqual(result.status, 'failed')
        self.assertIn('installer failed', result.detail)
        self.mac.relaunch.assert_called_once_with(self.app)
        self.mac.verify.assert_not_called()

    def test_install_recovery_rejects_invalid_signature_without_launch(self):
        self.backend.apply.side_effect = CommandError('installer failed')
        self.mac.current.side_effect = [[{'pid': 1001}], []]
        self.mac.check_signature.side_effect = CommandError('Signature invalid')
        result = self.handle()
        self.assertEqual(result.status, 'failed')
        self.assertIn('Signature invalid', result.detail)
        self.mac.relaunch.assert_not_called()

    def test_verification_failure_is_not_success_or_repeated_launch(self):
        self.mac.current.side_effect = [[{'pid': 1001}], [], [], [{'pid': 2002}]]
        self.mac.verify.side_effect = CommandError('Fresh process/path/version verification timed out')
        result = self.handle()
        self.assertEqual(result.status, 'failed')
        self.assertEqual(result.new_pids, [])
        self.mac.relaunch.assert_called_once_with(self.app)

    def test_signature_failure_must_never_reopen_changed_binary(self):
        self.mac.current.side_effect = None
        self.mac.current.return_value = [{'pid': 1001}]
        def quit_app(app):
            self.mac.current.return_value = []
            return True
        self.mac.quit.side_effect = quit_app
        self.mac.check_signature.side_effect = CommandError('Updated app signing team changed')
        self.assertEqual(self.handle().status, 'failed')
        self.mac.relaunch.assert_not_called()
        self.mac.verify.assert_not_called()

    def test_native_updater_existing_old_pid_requires_graceful_quit(self):
        self.backend.manages_lifecycle = True
        self.mac.current.side_effect = [[{'pid': 1001}], [{'pid': 1001}], []]
        self.assertEqual(self.handle().status, 'updated_and_relaunched')
        self.mac.quit.assert_called_once_with(self.app)
        self.mac.relaunch.assert_called_once_with(self.app)

    def test_native_updater_save_prompt_blocks_success(self):
        self.backend.manages_lifecycle = True
        self.mac.quit.return_value = False
        self.mac.current.side_effect = None
        self.mac.current.return_value = [{'pid': 1001}]
        self.assertEqual(self.handle().status, 'deferred')
        self.mac.verify.assert_not_called()
        self.mac.relaunch.assert_not_called()

    def test_native_updater_new_pid_needs_no_duplicate_quit_or_launch(self):
        self.backend.manages_lifecycle = True
        self.mac.current.side_effect = [[{'pid': 1001}], [{'pid': 2002}], [{'pid': 2002}]]
        self.assertEqual(self.handle().status, 'updated_and_relaunched')
        self.mac.quit.assert_not_called()
        self.mac.relaunch.assert_not_called()

    def test_unknown_updater_is_explicitly_unverified(self):
        self.backend.check.return_value = Check('unknown')
        self.assertEqual(self.handle().status, 'restart_only_unverified')
        self.backend.apply.assert_not_called()
        self.mac.signer.assert_not_called()

    def test_unmanaged_restarts_can_be_disabled(self):
        self.backend.check.return_value = Check('unknown', detail='Unsupported')
        self.assertEqual(self.handle({'restart_unmanaged': False}).status, 'unsupported')
        self.mac.quit.assert_not_called()

    def test_current_restarts_can_be_disabled_but_stale_process_restarts(self):
        self.backend.check.return_value = Check('current')
        self.assertEqual(self.handle({'restart_current': False}).status, 'current')
        self.mac.quit.assert_not_called()
        self.mac.current.side_effect = [[{'pid': 1001}], [], []]
        self.assertEqual(self.handle({'restart_current': False}, replace(self.app, stale=True)).status,
                         'updated_and_relaunched')
        self.mac.quit.assert_called_once()

    def test_backend_error_does_not_prevent_later_app_processing(self):
        self.registry.for_app.side_effect = [CommandError('unsupported'), self.backend]
        results = Coordinator(self.mac, self.registry, {}).run([self.app, self.app], apply=False)
        self.assertEqual([r.status for r in results], ['failed', 'planned'])


if __name__ == '__main__':
    unittest.main()
