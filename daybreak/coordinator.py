"""One pipeline for all updater families: check, install, relaunch, verify."""
import time
from .config import whitelisted
from .models import InstallResult, Result, protected
from .platform import CommandError, CommandTimeout

class Coordinator:
    def __init__(self, mac, registry, config):
        self.mac, self.registry, self.config = mac, registry, config

    def handle(self, app, apply=False):
        result = Result(app.bundle_id, app.name, 'planned', before=app.version,
                        old_pids=list(app.pids), before_build=app.build)
        if protected(app):
            result.status, result.detail = 'excluded', 'Protected host/system app'
            return result
        if whitelisted(app.bundle_id, self.config):
            result.status, result.detail = 'excluded', 'Whitelisted by configuration'
            return result
        spec = self.config.get('apps', {}).get(app.bundle_id, {})
        # Docker workload safety also applies to fallback restart-only mode.
        if app.bundle_id == 'com.docker.docker' and not spec.get('allow_workload_interruption'):
            result.status, result.detail = 'blocked', 'Docker restart can interrupt containers; enable allow_workload_interruption'
            return result
        recovery_needed = False
        install_started = False
        signer = None
        try:
            backend = self.registry.for_app(app)
            result.backend = backend.name
            if not apply:
                result.detail = 'Would check/update and gracefully relaunch; no updater checks or changes performed'
                if backend.name == 'restart-only':
                    result.detail = 'Would gracefully restart only; update availability cannot be verified'
                return result
            if not self.mac.current(app):
                result.status, result.detail = 'skipped', 'App stopped after inventory; not reopened'
                return result
            check = backend.check(app)
            if check.state == 'unknown' and not self.config.get('restart_unmanaged', True):
                result.status, result.detail = 'unsupported', check.detail
                return result
            if check.state == 'current' and not app.stale and not self.config.get('restart_current', True):
                result.status, result.detail = 'current', check.detail
                return result
            started = time.time()
            signer = None
            if check.state == 'available':
                signer = self.mac.signer(app)
            if not backend.manages_lifecycle:
                if not self.mac.quit(app):
                    result.status, result.detail = 'deferred', 'Quit refused or save prompt unresolved; no forced quit or update'
                    return result
                recovery_needed = True
            else:
                recovery_needed = True
            if check.state == 'available':
                install_started = True
                outcome = backend.apply(app)
                if isinstance(outcome, InstallResult):
                    result.update_outcome = outcome.state
                    result.detail = outcome.detail
                self.mac.check_signature(app, signer)
            # A native updater might relaunch; ensure old processes are actually gone.
            if any(row['pid'] in app.pids for row in self.mac.current(app)):
                if not self.mac.quit(app):
                    result.status, result.detail = 'deferred', 'Update attempted but original process has not exited'
                    return result
            if not self.mac.current(app):
                self.mac.relaunch(app)
            metadata, pids = self.mac.verify(app, started, check.target)
            result.after, result.new_pids = metadata['version'], pids
            result.after_build = metadata['build']
            result.verification = 'Fresh primary PID and launch time, verified executable path, and installed bundle version (not in-memory version introspection)'
            if hasattr(backend, 'health'):
                backend.health(app)
            changed = (metadata['version'], metadata['build'], metadata['fingerprint']) != (app.version, app.build, app.fingerprint)
            if check.state == 'unknown':
                result.status = 'restart_only_unverified'
                result.detail = 'Staged updates may have applied; latest-version availability is unknown'
            elif result.update_outcome == 'no_update':
                result.status = 'checked_and_relaunched'
                result.detail += '; app relaunched and verified, no upgrade claimed'
            elif changed:
                result.status = 'updated_and_relaunched'
            else:
                result.status = 'checked_and_relaunched'
                result.detail = 'Updater completed; installed version unchanged. Not proof of latest available release'
            recovery_needed = False
        except CommandTimeout as exc:
            result.status, result.detail = 'uncertain', str(exc)
            if install_started:
                recovery_needed = False  # An installer child may still be running.
                result.detail += '; no reopen/retry attempted while installer outcome is unknown'
        except (CommandError, ValueError, OSError, KeyError) as exc:
            result.status, result.detail = 'failed', str(exc)
        finally:
            if recovery_needed:
                try:
                    if not self.mac.current(app):
                        if install_started:
                            self.mac.check_signature(app, signer)
                        self.mac.relaunch(app)
                        result.detail += '; reopen requested after incomplete update'
                except (CommandError, OSError, ValueError, KeyError) as exc:
                    result.detail += f'; reopen failed: {exc}'
        return result

    def run(self, apps, apply=False):
        return [self.handle(app, apply) for app in apps]
