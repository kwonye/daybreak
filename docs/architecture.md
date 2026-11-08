# Architecture

Python standard-library orchestration with a small compiled Swift/AppKit bridge.

- `models.py`: immutable snapshot + structured outcomes + protected identifiers.
- `platform.py`: process inventory, plist metadata/fingerprints, graceful quit, open, signing checks, fresh-process verification.
- `backends.py`: capabilities and exact scoped commands; unsupported families stay explicit.
- `coordinator.py`: common check/install/relaunch/verify lifecycle, failure isolation and recovery.
- `state.py`: private atomic JSON, flock overlap control, Pacific-date gate and retention.
- `config.py`: strict safety-relevant types; strings like `"false"` cannot enable interruption.
- `native/AppBridge.swift`: `inventory` and identity-checked normal `quit PID BUNDLE_ID`. No Accessibility or forced termination.

## Boundaries

Updater families do not have interchangeable CLIs. Sparkle probe exit 0 means update available, exit 4 means no update, and exit 1 is failure. Probe cannot be combined with `--check-immediately`; installation uses that flag separately. Google `--update-apps` is deliberately not used because it affects every registered product. Docker's CLI plugin version is not the Desktop app version.

Updater processes may fail, time out or require interaction. A timeout during installation leaves an uncertain result, so the coordinator avoids concurrent recovery/retry. Native updaters may relaunch the app themselves; the coordinator checks PIDs first to avoid duplicate launches. An existing original PID prevents success.

Signature checks are defense in depth, not a universal package trust system. The supported updater remains responsible for its feed/download authenticity and signature verification. There is no custom downloader or package extraction/install engine.

Runtime state is local only, never uploaded. No telemetry, persistent credentials, login automation, LaunchAgent or cloud schedule is added. The CLI does not infer or bypass missing privileges.

## Known limitations

- Mac GUI session required. A sandbox can hide process inventory; this is an error, not an empty successful run.
- Unsaved data and browser/meeting/session restoration are app-dependent. Graceful termination cannot universally preserve them.
- Exact latest-version or in-memory version measurement is not universal. Reports name what was actually verified.
- Homebrew catalog freshness and auto-updating cask behavior are Homebrew-controlled. Legacy metadata and nonstandard app directories are not automatically mapped.
- `mas` can require login/permissions or change behavior by release; it is an optional third-party backend.
- Sleep/offline/logged-out machines do not run at exactly 08:00. No wake scheduling.
- No automatic rollback or downgrade. Updater/publisher changes require review.
- No preconfigured fully unattended Sparkle/mas dependencies or app-specific Electron feeds. Those need setup before download/install coverage expands beyond available backends.
