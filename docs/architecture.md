# Architecture

The SwiftUI app and bundled CLI both use the native engine in `DaybreakKit`.

- `MacApplications.swift` uses AppKit to enumerate processes and request normal termination. It also reads bundle metadata, verifies developer signatures, and checks that a fresh primary process launched.
- `UpdateBackends.swift` selects a supported updater and runs scoped commands. Optional adapters still require their own vendor tools.
- `UpdateCoordinator.swift` performs each check, installation, relaunch and verification, and isolates failures per app.
- `EngineConfiguration.swift` validates the existing JSON configuration. `NativeState.swift` preserves the existing report files, atomic writes, overlap lock and timezone-aware daily gate.
- `NativeEngine.swift` runs the engine and exposes the CLI contract. The GUI calls the same engine in a Swift actor and the CLI is packaged at `Daybreak.app/Contents/Helpers/daybreak`.

## Boundaries

Updater families do not have interchangeable CLIs. Sparkle probe exit 0 means update available, exit 4 means no update, and exit 1 is failure. Probe cannot be combined with `--check-immediately`; installation uses that flag separately. Google `--update-apps` is deliberately not used because it affects every registered product. Docker's CLI plugin version is not the Desktop app version.

Updater processes may fail, time out or require interaction. A timeout during installation leaves an uncertain result, so the coordinator avoids concurrent recovery/retry. Native updaters may relaunch the app themselves; the coordinator checks PIDs first to avoid duplicate launches. An existing original PID prevents success, including an original helper PID. Fresh same-bundle auxiliaries do not need to impersonate the primary binary or provide a launch timestamp. Primary identity comes from valid bundle metadata, or a unique confined executable observed by AppKit when that metadata is absent. The fallback path is captured before the update and reused during verification. Ambiguous, missing, non-executable, traversal, and bundle-escaping paths fail closed.

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

## Installation outcomes

Sparkle install exit 4 is a normal `no_update` outcome, not a failed installer. It still passes the same signature and primary-process verification before reporting a checked/relaunched app. Exit codes for network failures, permissions, interaction, or major-upgrade restrictions remain failures requiring attention. Reports include before/after build numbers so an unchanged marketing version does not hide a build change. Historic reports are not rewritten when verification code is improved.
