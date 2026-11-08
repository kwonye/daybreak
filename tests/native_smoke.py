#!/usr/bin/env python3
"""Opt-in native integration test; launches and restarts only a generated fixture.

Run from a logged-in macOS desktop session:
    python3 tests/native_smoke.py --run

Requires the Xcode command-line tools. Does not run ordinary app inventory,
select updater tools, modify installed apps, or participate in unittest discovery.
Generated source, helper, and fixture remain in a unique ignored .build directory.
"""
import argparse
from dataclasses import replace
import json
from pathlib import Path
import plistlib
import sys
import tempfile
import time

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))

from daybreak.backends import Backend
from daybreak.coordinator import Coordinator
from daybreak.models import App
from daybreak.platform import Mac, Runner, bundle_metadata

BUNDLE_ID = 'dev.daybreak.TestFixture'
VERSION = '1.2.3'
SOURCE = '''import AppKit
final class FixtureDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        return .terminateNow
    }
}
let app = NSApplication.shared
let delegate = FixtureDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
'''


class FixtureRegistry:
    """Never discovers or invokes an installed updater."""
    def __init__(self, path):
        self.path = str(path)

    def for_app(self, app):
        if app.bundle_id != BUNDLE_ID or app.path != self.path:
            raise ValueError('Smoke test may only operate its own fixture')
        return Backend()


def run():
    if sys.platform != 'darwin':
        raise RuntimeError('This optional smoke test requires macOS')
    build = ROOT / '.build'
    build.mkdir(exist_ok=True)
    workspace = Path(tempfile.mkdtemp(prefix='native-smoke-', dir=build))
    bundle = workspace / 'DaybreakTestFixture.app'
    executable = bundle / 'Contents/MacOS/DaybreakTestFixture'
    executable.parent.mkdir(parents=True)
    source = workspace / 'Fixture.swift'
    source.write_text(SOURCE)
    with (bundle / 'Contents/Info.plist').open('wb') as handle:
        plistlib.dump({'CFBundleIdentifier': BUNDLE_ID,
                      'CFBundleName': 'Daybreak Test Fixture',
                      'CFBundleExecutable': executable.name,
                      'CFBundlePackageType': 'APPL',
                      'CFBundleShortVersionString': VERSION,
                      'CFBundleVersion': '123',
                      'LSUIElement': True}, handle)
    runner = Runner()
    bridge = workspace / 'appbridge'
    runner.checked(['/usr/bin/xcrun', 'swiftc', '-O', str(ROOT / 'native/AppBridge.swift'), '-o', str(bridge)], 180)
    runner.checked(['/usr/bin/xcrun', 'swiftc', str(source), '-o', str(executable)], 180)
    mac = Mac(bridge, runner=runner, quit_timeout=15, launch_timeout=15)
    fixture = App(bundle_id=BUNDLE_ID, name='Daybreak Test Fixture', path=str(bundle),
                  pids=(), **bundle_metadata(bundle))
    result = None
    try:
        mac.relaunch(fixture)
        deadline = time.monotonic() + 15
        rows = []
        while time.monotonic() < deadline:
            rows = mac.current(fixture)
            if rows:
                break
            time.sleep(0.2)
        if not rows:
            raise AssertionError('Generated fixture never appeared in native inventory')
        fixture = replace(fixture, pids=tuple(row['pid'] for row in rows),
                          launches=tuple(row['launched'] for row in rows))
        result = Coordinator(mac, FixtureRegistry(bundle), {}).handle(fixture, apply=True)
        if result.status != 'restart_only_unverified':
            raise AssertionError(f'Unexpected result: {result.to_dict()}')
        if result.after != VERSION:
            raise AssertionError(f'Expected installed fixture version {VERSION}, got {result.after}')
        if not result.new_pids or set(result.old_pids) & set(result.new_pids):
            raise AssertionError('Relaunch did not replace all original PIDs')
    finally:
        # Exact unique bundle path plus bundle ID restricts cleanup to this fixture.
        # Never fall back to kill, forceTerminate, or another application's PID.
        if not mac.quit(fixture):
            raise RuntimeError(f'Fixture refused graceful cleanup: {bundle}')
        if mac.current(fixture):
            raise AssertionError(f'Fixture still running after cleanup: {bundle}')
    print(json.dumps({'status': 'passed', 'fixture': str(bundle),
                      'cleanup': 'gracefully quit', 'result': result.to_dict()}, indent=2))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--run', action='store_true', help='Opt in to launching the generated test fixture')
    args = parser.parse_args()
    if not args.run:
        parser.error('Explicit --run is required; this test launches its own fixture app')
    try:
        run()
    except (RuntimeError, ValueError, OSError, AssertionError) as exc:
        print(f'Native smoke test failed: {exc}', file=sys.stderr)
        return 1
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
