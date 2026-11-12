"""Schedule, private state, and CLI safety tests, using temporary files only."""
from contextlib import redirect_stdout, redirect_stderr
from datetime import datetime, timezone
import io
import json
from pathlib import Path
import stat
import tempfile
import unittest
from unittest.mock import Mock, patch

from daybreak import cli
from daybreak.state import due, load_json, locked, write_json


class ScheduleTests(unittest.TestCase):
    def utc(self, value):
        return datetime.fromisoformat(value).replace(tzinfo=timezone.utc)

    def test_standard_time_eight_am_is_sixteen_utc(self):
        self.assertFalse(due(self.utc('2026-11-08T15:59:59')))
        self.assertTrue(due(self.utc('2026-11-08T16:00:00')))

    def test_daylight_time_eight_am_is_fifteen_utc(self):
        self.assertFalse(due(self.utc('2026-07-08T14:59:59')))
        self.assertTrue(due(self.utc('2026-07-08T15:00:00')))

    def test_spring_and_fall_dst_transition_dates(self):
        for date, utc_hour in [('2026-03-08', 15), ('2026-11-01', 16)]:
            with self.subTest(date=date):
                self.assertFalse(due(self.utc(f'{date}T{utc_hour-1}:59:59')))
                self.assertTrue(due(self.utc(f'{date}T{utc_hour}:00:00')))

    def test_idempotent_for_local_date_including_next_utc_date(self):
        self.assertFalse(due(self.utc('2026-11-08T16:00:00'), '2026-11-08'))
        self.assertFalse(due(self.utc('2026-11-09T07:59:59'), '2026-11-08'))
        self.assertTrue(due(self.utc('2026-11-09T16:00:00'), '2026-11-08'))

    def test_previous_day_does_not_run_before_eight(self):
        self.assertFalse(due(self.utc('2026-11-09T15:59:59'), '2026-11-08'))


class StateTests(unittest.TestCase):
    def test_atomic_json_is_private_and_roundtrips(self):
        with tempfile.TemporaryDirectory() as temporary:
            path = Path(temporary) / 'private' / 'state.json'
            write_json(path, {'value': 1})
            self.assertEqual(load_json(path, None), {'value': 1})
            self.assertEqual(stat.S_IMODE(path.stat().st_mode), 0o600)
            self.assertEqual(stat.S_IMODE(path.parent.stat().st_mode), 0o700)
            write_json(path, {'value': 2})
            self.assertEqual(load_json(path, None), {'value': 2})
            self.assertEqual(list(path.parent.glob('.daybreak-*')), [])

    def test_missing_state_returns_default_but_corrupt_state_fails_closed(self):
        with tempfile.TemporaryDirectory() as temporary:
            path = Path(temporary) / 'state.json'
            self.assertEqual(load_json(path, {'default': True}), {'default': True})
            path.write_text('not json')
            with self.assertRaises(ValueError):
                load_json(path, {})

    def test_lock_excludes_overlap_and_releases_on_exception(self):
        with tempfile.TemporaryDirectory() as temporary:
            with self.assertRaisesRegex(ValueError, 'test'):
                with locked(temporary):
                    with self.assertRaisesRegex(RuntimeError, 'Another Daybreak run'):
                        with locked(temporary):
                            self.fail('Second process entered exclusive section')
                    raise ValueError('test')
            with locked(temporary):
                self.assertEqual(stat.S_IMODE((Path(temporary) / 'run.lock').stat().st_mode), 0o600)


class CliSafetyTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.bridge = self.root / 'bridge'
        self.bridge.touch()
        self.state = self.root / 'state'
        self.mac = Mock()
        self.mac.inventory.return_value = []
        for target, value in [('sys.platform', 'darwin')]:
            patcher = patch('daybreak.cli.' + target, value)
            patcher.start()
            self.addCleanup(patcher.stop)
        for target, kwargs in [('os.geteuid', {'return_value': 501}),
                               ('Mac', {'return_value': self.mac}),
                               ('Registry', {}), ('datetime', {})]:
            patcher = patch('daybreak.cli.' + target, **kwargs)
            value = patcher.start()
            self.addCleanup(patcher.stop)
            if target == 'datetime':
                value.now.return_value = datetime(2026, 11, 8, 16, tzinfo=timezone.utc)

    def run_cli(self, flags=(), config=None):
        argv = ['run', '--bridge', str(self.bridge), '--state-dir', str(self.state), *flags]
        if config is not None:
            path = self.root / 'config.json'
            path.write_text(json.dumps(config))
            argv += ['--config', str(path)]
        with redirect_stdout(io.StringIO()), redirect_stderr(io.StringIO()):
            return cli.main(argv)

    def test_dry_run_does_not_create_any_state_or_consume_schedule(self):
        self.assertEqual(self.run_cli(['--due']), 0)
        self.assertFalse(self.state.exists())
        self.mac.inventory.assert_called_once()

    def test_apply_consumes_local_date_and_second_run_does_nothing(self):
        self.assertEqual(self.run_cli(['--due', '--apply']), 0)
        self.assertEqual(load_json(self.state / 'schedule.json', {})['last_date'], '2026-11-08')
        self.assertEqual(self.run_cli(['--due', '--apply']), 0)
        self.mac.inventory.assert_called_once()

    def test_failure_after_consumption_does_not_retry_same_day(self):
        self.mac.inventory.side_effect = RuntimeError('inventory failure')
        self.assertEqual(self.run_cli(['--due', '--apply']), 1)
        self.assertEqual(self.run_cli(['--due', '--apply']), 0)
        self.mac.inventory.assert_called_once()

    def test_invalid_config_fails_before_inventory(self):
        invalid = [[], {'hour': True}, {'hour': -1}, {'hour': 24}, {'hour': '8'},
                   {'timezone': 'Not/A_Real_Zone'}, {'apps': []}, {'apps': {'x': []}},
                   {'exclude': 'com.example.Editor'}, {'whitelist': 'com.example.Editor'},
                   {'whitelist': ['']}, {'whitelist': [1]}, {'restart_current': 'false'},
                   {'apps': {'com.docker.docker': {'allow_workload_interruption': 'false'}}}]
        for config in invalid:
            with self.subTest(config=config):
                self.assertEqual(self.run_cli(['--due'], config), 1)
        self.mac.inventory.assert_not_called()

    def apps(self):
        from daybreak.models import App
        return [App(b, b, '/Applications/X.app', '1', '1', (1,)) for b in ('org.a.One', 'org.a.Two', 'org.b.Three')]

    def run_report(self, flags=(), config=None):
        buf = io.StringIO()
        argv = ['run', '--bridge', str(self.bridge), '--state-dir', str(self.state), *flags]
        if config is not None:
            path = self.root / 'config.json'
            path.write_text(json.dumps(config))
            argv += ['--config', str(path)]
        with patch('daybreak.cli.Coordinator') as coord, redirect_stdout(buf), redirect_stderr(io.StringIO()):
            coord.return_value.run.return_value = []
            self.assertEqual(cli.main(argv), 0)
        config_used = coord.call_args[0][2]
        return config_used, [a.bundle_id for a in coord.return_value.run.call_args[0][0]]

    def test_skip_flag_merges_into_whitelist_for_run_only(self):
        self.mac.inventory.return_value = self.apps()
        config, _ = self.run_report(['--skip', 'org.a.*', '--skip', 'x'], {'whitelist': ['y']})
        self.assertEqual(config['whitelist'], ['y', 'org.a.*', 'x'])
        self.assertFalse((self.root / 'config.json').read_text().count('org.a.*'))

    def test_whitelist_beats_only(self):
        from daybreak.coordinator import Coordinator
        self.mac.inventory.return_value = self.apps()
        config, ids = self.run_report(['--only', 'org.a.One', '--only', 'org.b.Three', '--skip', 'org.a.One'])
        self.assertEqual(ids, ['org.a.One', 'org.b.Three'])
        result = Coordinator(Mock(), Mock(), config).handle(self.apps()[0], False)
        self.assertEqual((result.status, result.detail), ('excluded', 'Whitelisted by configuration'))

    def test_empty_skip_is_rejected(self):
        self.assertEqual(self.run_cli(['--skip', '']), 1)
        self.mac.inventory.assert_not_called()

    def test_inventory_reports_whitelisted_and_protected_with_config(self):
        from daybreak.models import App
        self.mac.inventory.return_value = self.apps() + [App('com.openai.x', 'x', '/Applications/x.app', '1', '1', (2,))]
        path = self.root / 'config.json'
        path.write_text(json.dumps({'whitelist': ['org.a.*']}))
        def inv(*extra):
            buf = io.StringIO()
            with redirect_stdout(buf):
                self.assertEqual(cli.main(['inventory', '--bridge', str(self.bridge), *extra]), 0)
            return json.loads(buf.getvalue())
        rows = inv('--config', str(path))
        self.assertEqual([(r['whitelisted'], r['protected']) for r in rows],
                         [(True, False), (True, False), (False, False), (False, True)])
        self.assertNotIn('whitelisted', inv()[0])
        self.assertEqual(rows[0]['bundle_id'], 'org.a.One')

    def test_root_apply_is_refused_without_inventory(self):
        with patch('daybreak.cli.os.geteuid', return_value=0):
            self.assertEqual(self.run_cli(['--apply']), 1)
        self.mac.inventory.assert_not_called()


if __name__ == '__main__':
    unittest.main()
