"""macOS boundary. All subprocess arguments are arrays, never shell programs."""
import hashlib
import json
import os
from pathlib import Path
import plistlib
import subprocess
import time
from .models import App, protected

class CommandError(RuntimeError):
    pass

class CommandTimeout(CommandError):
    pass

class Runner:
    def run(self, argv, timeout=120):
        try:
            result = subprocess.run([str(x) for x in argv], capture_output=True,
                                    text=True, timeout=timeout, stdin=subprocess.DEVNULL)
        except subprocess.TimeoutExpired as exc:
            raise CommandTimeout(f'{Path(argv[0]).name}: timeout; completion is uncertain') from exc
        except OSError as exc:
            raise CommandError(f'{Path(argv[0]).name}: {type(exc).__name__}') from exc
        return result

    def checked(self, argv, timeout=120):
        result = self.run(argv, timeout)
        if result.returncode:
            # Do not retain arbitrary updater output, URLs, tokens, or environment.
            raise CommandError(f'{Path(argv[0]).name} exited {result.returncode}')
        return result.stdout


def _safe_executable(root, candidate, *, observed=False):
    """Resolve a real executable within this bundle, never an escaping symlink."""
    try:
        path = Path(candidate)
        if not path.is_absolute():
            return ''
        root_real = root.resolve(strict=True)
        executable = path.resolve(strict=True)
        executable.relative_to(root_real / 'Contents')
        if observed and executable.parent != (root_real / 'Contents/MacOS').resolve(strict=True):
            return ''
        if not executable.is_file() or not os.access(executable, os.X_OK):
            return ''
        return str(executable)
    except (OSError, TypeError, ValueError, RuntimeError):
        return ''


def bundle_metadata(path, observed_executables=()):
    root = Path(path)
    with (root / 'Contents/Info.plist').open('rb') as handle:
        info = plistlib.load(handle)
    declared = info.get('CFBundleExecutable')
    executable, source = '', 'unresolved'
    if isinstance(declared, str) and declared and declared not in ('.', '..') and Path(declared).name == declared:
        executable = _safe_executable(root, root / 'Contents/MacOS' / declared)
        if executable:
            source = 'plist'
    elif declared in (None, ''):
        # Some vendor bundles omit CFBundleExecutable. Use only a unique executable
        # observed by AppKit, confined to this bundle's MacOS directory. Never guess.
        candidates = {_safe_executable(root, item, observed=True) for item in observed_executables}
        candidates.discard('')
        if len(candidates) == 1:
            executable = candidates.pop()
            source = 'running-process'
    fingerprint = ''
    if executable:
        with Path(executable).open('rb') as handle:
            fingerprint = hashlib.file_digest(handle, 'sha256').hexdigest()
    hints = []
    if (root / 'Contents/Frameworks/Sparkle.framework').exists():
        hints.append('sparkle')
    if (root / 'Contents/Frameworks/Squirrel.framework').exists():
        hints.append('squirrel')
    if (root / 'Contents/Frameworks/Electron Framework.framework').exists():
        hints.append('electron')
    if (root / 'Contents/_MASReceipt/receipt').exists():
        hints.append('app-store')
    return dict(version=str(info.get('CFBundleShortVersionString', '')),
                build=str(info.get('CFBundleVersion', '')), executable=executable,
                fingerprint=fingerprint, hints=tuple(hints), executable_source=source)


def same_executable(observed, expected):
    if not observed or not expected:
        return False
    try:
        return Path(observed).resolve(strict=True) == Path(expected).resolve(strict=True)
    except (OSError, TypeError, ValueError, RuntimeError):
        return False


def executable_is_stale(output, executable):
    """Compare the mapped executable vnode to the current disk inode (no guessing)."""
    try:
        current_inode = os.stat(executable).st_ino
    except OSError:
        return False
    fields = {}
    for line in output.splitlines() + ['fEND']:
        if line.startswith('f'):
            if fields.get('n', '').removesuffix(' (deleted)') == executable:
                return fields.get('i', str(current_inode)) != str(current_inode)
            fields = {}
        elif line and line[0] in 'ni':
            fields[line[0]] = line[1:]
    return False

class Mac:
    def __init__(self, bridge, runner=None, quit_timeout=60, launch_timeout=60):
        self.bridge = Path(bridge)
        self.runner = runner or Runner()
        self.quit_timeout = quit_timeout
        self.launch_timeout = launch_timeout

    def records(self):
        records = json.loads(self.runner.checked([self.bridge, 'inventory']))
        if not records:
            raise CommandError('No accessible app inventory; run in the logged-in GUI session with process access')
        return records

    def inventory(self):
        groups = {}
        for row in self.records():
            groups.setdefault((row['bundle_id'], row['path']), []).append(row)
        apps = []
        for (bundle_id, path), rows in sorted(groups.items()):
            try:
                data = bundle_metadata(path, [row['executable'] for row in rows])
            except (OSError, plistlib.InvalidFileException):
                continue
            stale = False
            for row in rows:
                r = self.runner.run(['/usr/sbin/lsof', '-a', '-p', str(row['pid']), '-d', 'txt', '-Ffni'], 15)
                stale |= executable_is_stale(r.stdout, data['executable'])
            apps.append(App(bundle_id=bundle_id, name=rows[0]['name'], path=path,
                            pids=tuple(row['pid'] for row in rows),
                            launches=tuple(row['launched'] for row in rows), stale=stale, **data))
        return apps

    def current(self, app):
        return [r for r in self.records() if r['bundle_id'] == app.bundle_id and r['path'] == app.path]

    def quit(self, app):
        if protected(app):
            raise CommandError('Protected application')
        # Resolve fresh records to avoid requesting quit of a reused PID.
        for row in self.current(app):
            self.runner.checked([self.bridge, 'quit', str(row['pid']), app.bundle_id], 15)
        until = time.monotonic() + self.quit_timeout
        while time.monotonic() < until:
            if not self.current(app):
                return True
            time.sleep(0.5)
        return False

    def relaunch(self, app):
        if protected(app):
            raise CommandError('Protected application')
        self.runner.checked(['/usr/bin/open', '-g', app.path], 15)

    def verify(self, app, before_install, target=''):
        until = time.monotonic() + self.launch_timeout
        while time.monotonic() < until:
            rows = self.current(app)
            # Original helpers must also be gone, but new auxiliaries do not stand
            # in for the main executable and may legitimately have no launch date.
            if rows and not any(row['pid'] in app.pids for row in rows):
                metadata = bundle_metadata(app.path, [app.executable])
                if not metadata['executable'] or not metadata['fingerprint']:
                    raise CommandError('Cannot resolve a unique executable within the app bundle')
                primary = [row for row in rows if same_executable(row['executable'], metadata['executable'])]
                fresh = primary and all(isinstance(row.get('launched'), (int, float))
                                        and row['launched'] >= before_install - 1 for row in primary)
                expected = not target or target in (metadata['version'], metadata['build'])
                if fresh and expected:
                    return metadata, [row['pid'] for row in primary]
            time.sleep(0.5)
        raise CommandError('Fresh primary process/path/version verification timed out')

    def signer(self, app):
        verification = self.runner.run(['/usr/bin/codesign', '--verify', '--deep', '--strict', app.path], 120)
        if verification.returncode:
            if 'resource fork, Finder information, or similar detritus not allowed' in verification.stderr:
                raise CommandError('Strict signature verification blocked by Finder/resource metadata; no metadata was removed')
            raise CommandError(f'Strict signature verification failed (codesign exited {verification.returncode})')
        result = self.runner.run(['/usr/bin/codesign', '-dv', '--verbose=4', app.path], 30)
        team = next((line.split('=', 1)[1] for line in result.stderr.splitlines()
                     if line.startswith('TeamIdentifier=')), '')
        if result.returncode or not team or team == 'not set':
            raise CommandError('Update requires an existing valid developer signing identity')
        return team

    def check_signature(self, app, expected_team):
        if self.signer(app) != expected_team:
            raise CommandError('Updated app signing team changed; manual review required')
        with (Path(app.path) / 'Contents/Info.plist').open('rb') as handle:
            info = plistlib.load(handle)
        if info.get('CFBundleIdentifier') != app.bundle_id:
            raise CommandError('Updated app bundle identity changed')
