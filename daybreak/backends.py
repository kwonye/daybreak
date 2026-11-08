"""Supported update mechanisms; updater families are hints, never APIs."""
import json
from pathlib import Path
import re
import shutil
import time
from .models import Check
from .platform import CommandError

class Backend:
    name = 'restart-only'
    manages_lifecycle = False
    def check(self, app):
        return Check('unknown', detail='No supported updater configured; restart may apply a staged update')
    def apply(self, app):
        pass

class Sparkle(Backend):
    name = 'sparkle'
    def __init__(self, runner, executable):
        self.runner, self.executable = runner, executable
    def check(self, app):
        # Probe is deliberately NOT combined with --check-immediately.
        result = self.runner.run([self.executable, app.path, '--probe', '--user-agent-name', 'Daybreak'], 120)
        if result.returncode == 0:
            return Check('available', detail='Sparkle found an update')
        if result.returncode == 4:
            return Check('current', detail='Sparkle reports no update')
        raise CommandError(f'Sparkle probe exited {result.returncode}; needs attention')
    def apply(self, app):
        self.runner.checked([self.executable, app.path, '--check-immediately', '--user-agent-name', 'Daybreak'], 900)

class Brew(Backend):
    name = 'homebrew'
    def __init__(self, runner, executable, token):
        if not re.fullmatch(r'[a-z0-9][a-z0-9@+_.-]*', token):
            raise ValueError('Invalid Homebrew cask token')
        self.runner, self.executable, self.token = runner, executable, token
    def check(self, app):
        data = json.loads(self.runner.checked([self.executable, 'outdated', '--cask', '--json=v2', self.token], 180))
        match = next((x for x in data.get('casks', []) if x.get('name') == self.token), None)
        return Check('available' if match else 'current', detail='Homebrew cask catalog result')
    def apply(self, app):
        # Scope to one existing managed cask, never bulk/adopt/reinstall/greedy.
        self.runner.checked([self.executable, 'upgrade', '--cask', self.token], 900)

class MAS(Backend):
    name = 'app-store'
    def __init__(self, runner, executable, app_id):
        if not str(app_id).isdigit():
            raise ValueError('App Store ID must be numeric')
        self.runner, self.executable, self.app_id = runner, executable, str(app_id)
    def check(self, app):
        output = self.runner.checked([self.executable, 'outdated'], 180)
        for line in output.splitlines():
            if line.split() and line.split()[0] == self.app_id:
                return Check('available', detail='mas reports an update')
        return Check('current', detail='mas did not list this app as outdated')
    def apply(self, app):
        self.runner.checked([self.executable, 'update', self.app_id], 900)

class Docker(Backend):
    name = 'docker'
    manages_lifecycle = True
    def __init__(self, runner, executable):
        self.runner, self.executable = runner, executable
    def check(self, app):
        # Docker has no stable machine-readable check result. Do not guess from prose.
        return Check('available', detail='Request native check/apply; availability unknown until finished')
    def apply(self, app):
        self.runner.checked([self.executable, 'desktop', 'update', '--quiet'], 1200)
    def health(self, app):
        until = time.monotonic() + 90
        while time.monotonic() < until:
            result = self.runner.run([self.executable, 'info', '--format', '{{.ServerVersion}}'], 10)
            if result.returncode == 0 and result.stdout.strip():
                return
            time.sleep(1)
        raise CommandError('Docker GUI relaunched but engine did not become ready')

class Google(Backend):
    name = 'google'
    def __init__(self, runner, executable):
        self.runner, self.executable = runner, executable
    def check(self, app):
        helper = Path(self.executable)
        updater = helper.parents[4] / 'MacOS/GoogleUpdater'
        if not helper.is_file() or not updater.is_file():
            raise CommandError('Existing user-scope Google updater/helper missing')
        output = self.runner.checked([helper, '--print-tickets', '--productid', app.bundle_id,
                                      '--user-store'], 60)
        product = re.search(r'^\s*productID=(.+)$', output, re.MULTILINE)
        location = re.search(r'^\s*xc=<[^\n]* path=(.*)>$', output, re.MULTILINE)
        version = re.search(r'^\s*version=(.+)$', output, re.MULTILINE)
        if (not product or not location or not version
                or product.group(1).strip().lower() != app.bundle_id.lower()
                or location.group(1) != app.path):
            raise CommandError('Google registration does not match this app path')
        return Check('available', detail='Scoped native check/apply; availability unknown until finished')
    def apply(self, app):
        self.check(app)
        self.runner.checked([self.executable, '--install', '--productid', app.bundle_id,
                             '--user-store'], 900)

class CommandAdapter(Backend):
    name = 'command'
    def __init__(self, runner, settings):
        self.runner, self.settings = runner, settings
        for key in ('check', 'apply'):
            argv = settings.get(key)
            if not isinstance(argv, list) or not argv or not all(isinstance(x, str) and x for x in argv):
                raise ValueError(f'{key} must be a nonempty argv array')
            if not Path(argv[0]).is_absolute():
                raise ValueError(f'{key} executable must be an absolute path')
    def command(self, key, app):
        # Literal replacements only; no eval, shell, or dynamic command downloads.
        return [x.replace('{app_path}', app.path).replace('{bundle_id}', app.bundle_id)
                for x in self.settings[key]]
    def check(self, app):
        data = json.loads(self.runner.checked(self.command('check', app), 180))
        if data.get('state') not in ('available', 'current', 'unknown'):
            raise CommandError('Adapter returned an invalid state')
        target = data.get('target_version', '')
        if not isinstance(target, str) or (data['state'] == 'available' and not target):
            raise CommandError('Available adapter update must include target_version')
        return Check(data['state'], target)
    def apply(self, app):
        self.runner.checked(self.command('apply', app), 900)

class Registry:
    def __init__(self, runner, config):
        self.runner, self.config = runner, config
        self.casks = {}
        self.brew = shutil.which('brew')
        if self.brew:
            # Read only installed metadata, never `brew info` (which can hit the network).
            prefix = Path(self.brew).resolve().parents[2]
            roots = {Path('/opt/homebrew/Caskroom'), Path('/usr/local/Caskroom'), prefix / 'Caskroom'}
            for root in roots:
                if not root.is_dir():
                    continue
                for metadata in root.glob('*/.metadata/*/*/Casks/*.json'):
                    try:
                        cask = json.loads(metadata.read_text())
                        token = metadata.parent.parent.parent.parent.parent.name
                        for artifact in cask.get('artifacts', []):
                            names = artifact.get('app', []) if isinstance(artifact, dict) else []
                            if names and isinstance(names[0], str):
                                destination = names[0]
                                if len(names) > 1 and isinstance(names[1], dict):
                                    destination = names[1].get('target', destination)
                                self.casks[str(Path('/Applications') / destination)] = token
                    except (OSError, ValueError, KeyError):
                        continue
    def for_app(self, app):
        spec = self.config.get('apps', {}).get(app.bundle_id, {})
        kind = spec.get('backend')
        if kind == 'command':
            return CommandAdapter(self.runner, spec)
        if kind == 'sparkle' or (not kind and 'sparkle' in app.hints and self.config.get('sparkle_cli')):
            executable = spec.get('executable') or self.config.get('sparkle_cli')
            if not executable or not Path(executable).is_file():
                raise CommandError('Official Sparkle CLI not configured or missing')
            return Sparkle(self.runner, executable)
        if kind == 'homebrew' or (not kind and app.path in self.casks):
            token = self.casks.get(app.path)
            if not self.brew or not token or (spec.get('cask') and token != spec['cask']):
                raise CommandError('Exact app path is not an installed Homebrew cask')
            return Brew(self.runner, self.brew, token)
        if kind == 'app-store':
            executable = spec.get('executable') or shutil.which('mas')
            if not executable or 'app-store' not in app.hints:
                raise CommandError('mas missing or app has no App Store receipt')
            return MAS(self.runner, executable, spec.get('app_id', ''))
        if kind == 'docker':
            if app.bundle_id != 'com.docker.docker' or not spec.get('allow_workload_interruption'):
                raise CommandError('Docker workload interruption must be explicitly enabled')
            return Docker(self.runner, str(Path(app.path) / 'Contents/Resources/bin/docker'))
        if kind == 'google' or (not kind and app.bundle_id == 'com.google.Chrome'):
            if app.bundle_id != 'com.google.Chrome':
                raise CommandError('Google adapter currently supports Chrome only')
            executable = spec.get('executable') or str(Path.home() / 'Library/Application Support/Google/GoogleUpdater/Current/GoogleUpdater.app/Contents/Helpers/GoogleSoftwareUpdate.bundle/Contents/Helpers/ksadmin')
            if not Path(executable).is_file():
                if kind:
                    raise CommandError('Existing user-scope Google updater helper missing')
                return Backend()
            return Google(self.runner, executable)
        if kind not in (None, 'restart-only'):
            raise ValueError(f'Unknown backend: {kind}')
        return Backend()
