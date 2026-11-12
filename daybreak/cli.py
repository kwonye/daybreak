import argparse
from datetime import datetime, timezone
import json
import os
from pathlib import Path
import sys
from zoneinfo import ZoneInfo
from .backends import Registry
from .coordinator import Coordinator
from .config import validate, whitelisted
from .models import protected
from .platform import Mac, Runner, CommandError
from .state import DEFAULT_ZONE, due, load_json, locked, save_report, write_json

ROOT = Path(__file__).resolve().parent.parent
DEFAULT_STATE = Path.home() / 'Library/Application Support/Daybreak'


def parser():
    p = argparse.ArgumentParser(description='Check, update, relaunch and verify running macOS apps. Dry-run by default.')
    p.add_argument('command', choices=['inventory', 'run', 'status'])
    mode = p.add_mutually_exclusive_group()
    mode.add_argument('--apply', action='store_true', help='Allow update installation and graceful app interruption')
    mode.add_argument('--dry-run', action='store_true', help='Read-only plan (default)')
    p.add_argument('--due', action='store_true', help='At most once per Pacific date, at/after 08:00')
    p.add_argument('--config', type=Path)
    p.add_argument('--state-dir', type=Path, default=DEFAULT_STATE)
    p.add_argument('--bridge', type=Path, default=ROOT / '.build/appbridge')
    p.add_argument('--only', action='append', default=[], metavar='BUNDLE_ID')
    p.add_argument('--skip', action='append', default=[], metavar='BUNDLE_ID_OR_PATTERN',
                   help='Whitelist an app or glob for this run only (repeatable)')
    return p


def main(argv=None):
    args = parser().parse_args(argv)
    try:
        if args.command == 'status':
            print(json.dumps(load_json(args.state_dir / 'latest.json', {'status': 'never_run'}), indent=2))
            return 0
        if sys.platform != 'darwin':
            raise RuntimeError('App operations require macOS')
        if args.apply and os.geteuid() == 0:
            raise RuntimeError('Run as the logged-in desktop user, never root')
        if not args.bridge.is_file():
            raise RuntimeError('Native helper missing; run ./scripts/build.sh first')
        config = load_json(args.config, {}) if args.config else {}
        config = {**config, 'whitelist': [*config.get('whitelist', []), *args.skip]} if args.skip else config
        validate(config)
        mac = Mac(args.bridge, quit_timeout=config.get('quit_timeout_seconds', 60))
        if args.command == 'inventory':
            rows = []
            for app in mac.inventory():
                row = app.to_dict()
                if args.config:
                    row['whitelisted'], row['protected'] = whitelisted(app.bundle_id, config), protected(app)
                rows.append(row)
            print(json.dumps(rows, indent=2))
            return 0
        def execute():
            now = datetime.now(timezone.utc)
            state = load_json(args.state_dir / 'schedule.json', {})
            zone = config.get('timezone', DEFAULT_ZONE)
            hour = config.get('hour', 8)
            if not isinstance(hour, int) or isinstance(hour, bool) or not 0 <= hour <= 23:
                raise ValueError('hour must be an integer from 0 through 23')
            if args.due and not due(now, state.get('last_date', ''), zone, hour):
                print(json.dumps({'status': 'not_due', 'timezone': zone, 'hour': hour}))
                return 0
            if args.apply and args.due:
                # Consume before work: crashes must not trigger repeated daily interruptions.
                write_json(args.state_dir / 'schedule.json', {
                    'last_date': now.astimezone(ZoneInfo(zone)).date().isoformat(),
                    'started_at': now.isoformat(), 'status': 'started'})
            apps = mac.inventory()
            if args.only:
                apps = [a for a in apps if a.bundle_id in args.only]
            coordinator = Coordinator(mac, Registry(Runner(), config), config)
            results = coordinator.run(apps, args.apply)
            report = {'started_at': now.isoformat(), 'apply': args.apply, 'timezone': zone,
                      'results': [r.to_dict() for r in results]}
            if args.apply:
                save_report(args.state_dir, report)
            print(json.dumps(report, indent=2))
            return 2 if any(r.status in ('failed', 'blocked', 'deferred', 'unsupported', 'uncertain', 'restart_only_unverified') for r in results) else 0
        if args.apply:
            with locked(args.state_dir):
                return execute()
        return execute()
    except (ValueError, OSError, RuntimeError, CommandError) as exc:
        print(json.dumps({'status': 'error', 'detail': str(exc)}), file=sys.stderr)
        return 1

if __name__ == '__main__':
    raise SystemExit(main())
