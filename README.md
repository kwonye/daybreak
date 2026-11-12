# Daybreak

A local macOS update coordinator for the apps that are running when the daily job starts. It checks supported updaters, applies updates, gracefully closes/reopens apps when needed, and verifies that fresh processes launched from the installed bundles.

**Dry-run is the default. This is a conservative v0.1, not a universal updater.** There is no supported universal external API for every Sparkle or Electron application. Unsupported apps can be restarted to activate updates they already downloaded, but are explicitly reported as `restart_only_unverified`.

## Quick start

Requires macOS, Python 3.11+, and Xcode Command Line Tools (for the small AppKit helper). There are no Python runtime dependencies. Run from the checkout; the compiled helper is local and is not distributed as a signed/notarized binary.

```sh
./scripts/build.sh
./scripts/daybreak inventory
./scripts/daybreak run --dry-run
```

A dry-run reads app/process metadata and local installed-cask metadata. It **does not** invoke an updater, make network requests, quit/relaunch apps, or write run state. If the environment cannot enumerate running apps, it fails instead of reporting an empty successful run.

To configure, copy `examples/config.example.json` outside the repository, edit it, then preview again:

```sh
mkdir -p "$HOME/.config/daybreak"
cp examples/config.example.json "$HOME/.config/daybreak/config.json"
./scripts/daybreak run --dry-run --config "$HOME/.config/daybreak/config.json"
```

To actually interrupt and update the running apps:

```sh
./scripts/daybreak run --apply --config "$HOME/.config/daybreak/config.json"
```

Use `--only com.google.Chrome` (repeatable) to limit a run. Do not run as root. The process must run in the logged-in user's GUI session and have permission to enumerate/terminate apps. It does not request Accessibility access or change macOS permissions. Restricted execution environments may need their supported approval mechanism; do not work around access denials.

## What works

| Backend | Behavior | Prerequisites / limits |
| --- | --- | --- |
| Chrome | Uses Google's documented `ksadmin --install --productid com.google.Chrome --user-store` compatibility API, then relaunches | Existing user-scope Google updater and exact Chrome registration must match. No updater installation, system scope, or update-all command |
| Sparkle | Official external Sparkle CLI probes, installs, then coordinator relaunches | Supply `sparkle_cli`; app must expose a compatible feed/configuration. No feed overrides, signature bypass, automatic major-upgrade opt-in, or internal Autoupdate/ShipIt invocation |
| Homebrew cask | Checks/upgrades one existing managed cask | Exact `/Applications` app path must match installed JSON cask metadata. No automatic adoption, reinstall, bulk or greedy updates. Legacy Ruby metadata/custom app directories require an explicit adapter |
| Mac App Store | Optional `mas outdated` / `mas update ID` | User-installed `mas`, App Store receipt, explicit numeric `app_id`, signed-in account. `mas` is third-party, not an Apple API. It may need user interaction; no sudo or automatic dependency install |
| Docker Desktop | Native `docker desktop update --quiet`, fresh-process check, then engine health check | Explicit `allow_workload_interruption: true`. Containers, Kubernetes and VM workloads can stop. Docker's command has no stable machine-readable availability response |
| Electron / Squirrel / unknown | Graceful restart to apply a vendor-staged update | No generic external update API. Latest-release availability is unknown unless a supported command adapter is configured |

By default, apps reported current are still gracefully restarted, and unsupported apps get a restart-only attempt. This matches an interrupt-at-08:00 workflow and covers updates activated on next launch. Set `restart_current` or `restart_unmanaged` to `false` to narrow that behavior.

System apps, nested helper apps, updater services, OpenAI host/control apps, and Tailscale networking apps are protected and never quit. User exclusions are additive. No cloud automation or LaunchAgent is created or modified by this repository.

## Safety and honest verification

- Takes one initial running-app snapshot; never starts an app that was not running. If it stops before its turn, it is skipped.
- Requests normal AppKit termination and waits. Save prompts, quit refusals and timeouts defer the app. **Never force-quits, sends kill signals, dismisses save dialogs, or reboots.**
- Graceful quit is **not a guarantee against data loss**. Browser forms, incognito sessions, meetings and app-specific state may still be lost. Reopening a browser does not guarantee tab/session restoration. Configure exclusions if necessary.
- Updates must preserve a valid developer signing team and bundle ID. Invalid signatures block relaunch; changing publishers requires manual review.
- After an installer failure, only requests recovery launch if the app is absent and its signature still verifies. On installer timeout, completion is uncertain and no automatic reopen/retry is attempted.
- Success requires a fresh primary PID/start time, verified executable path, current bundle version and fingerprint. New auxiliary processes sharing the bundle ID are not mistaken for the main executable, but any original PID still present blocks verification. Command success alone is not enough. This verifies **“relaunched installed version”**, not a direct measurement of arbitrary in-memory application versions, nor proof that no newer release exists.
- Isolates each app's failure, runs sequentially, locks overlapping jobs, writes private JSON reports, and suppresses arbitrary updater stdout/stderr from reports to reduce accidental sensitive logging.

When a vendor omits `CFBundleExecutable`, Daybreak uses only a unique executable observed by macOS inside that bundle’s `Contents/MacOS` directory. It does not guess from directory contents, accept escaping symlinks, or silently switch to a helper after updating.

Sparkle exit 4 during installation means no update is available at that point. Daybreak still verifies the signature and relaunch, reports `checked_and_relaunched`, and does not claim an upgrade.

The current process may already be older than its bundle on disk. Daybreak compares mapped executable inode with current disk inode when `lsof` can establish that fact. Lack of that signal is not proof of freshness; the default fresh-process relaunch handles that case.

## Daily 08:00 Pacific integration

Use the **existing** daily cloud automation to invoke this on the Mac. Do not create a second schedule:

```sh
cd "$HOME/Developer/github/kwonye/daybreak"
/opt/homebrew/bin/python3 -m daybreak run --apply --due \
  --config "$HOME/.config/daybreak/config.json"
```

Use the actual checkout and Python paths on your machine. The gate uses `America/Los_Angeles`, so DST follows Pacific wall time. It allows one run per local calendar date at or after 08:00. A late same-day invocation catches up; it does not wake a sleeping Mac, run while logged out, or replay missed days. The existing scheduler remains responsible for invoking the command.

The date is consumed **before work starts** to avoid repeated interruptions after a crash. Failures are not automatically retried that day. Inspect the report and use a manually targeted `--apply --only ...` without `--due` when safe. Dry-run never consumes the date. Keep one consistent state directory across triggers.

No real update or daily schedule installation is performed by building/testing this project.

## Reports and exit codes

```sh
./scripts/daybreak status
```

Default private state: `~/Library/Application Support/Daybreak/`.

- `latest.json`: last actual run, including before/after versions and builds, primary PIDs, and updater outcome
- `runs/*.json`: last 30 runs
- `schedule.json`: daily gate; `run.lock`: overlap lock
- stdout: full JSON report (inventory includes local app paths; treat it as private)

Status values distinguish `updated_and_relaunched`, `checked_and_relaunched`, `restart_only_unverified`, `current`, `deferred`, `blocked`, `failed`, `uncertain`, `unsupported`, `skipped`, `excluded`, and dry-run `planned`.

Exit 0 means no attention state was reported (not “everything is latest”). Exit 2 means one or more apps need attention or have unverified update coverage. Exit 1 means setup/configuration/inventory failed. Dry-run may return 2 to expose blocked configuration such as Docker's missing workload opt-in.

## Mac app

`app/` is an optional native SwiftUI front end (macOS 14+, no dependencies). It does not reimplement anything: every action runs the Python engine (`python3 -B -m daybreak … --bridge … --config … --state-dir …`) and renders its JSON.

```sh
./scripts/build-app.sh          # .build/Daybreak.app (universal, hardened runtime) + .build/dist/Daybreak-<version>.zip
open .build/Daybreak.app
cd app && swift run DaybreakApp # development; uses this checkout's engine and .build/appbridge (run ./scripts/build.sh first)
cd app && swift test            # unit tests; DAYBREAK_INTEGRATION=1 adds read-only engine checks
```

- **Running Apps** lists `inventory` with protected/whitelisted badges and a per-app whitelist checkbox (protected apps can be hidden). Daybreak never includes itself in an update run.
- **Whitelist** edits `whitelist` in `~/.config/daybreak/config.json`: exact bundle IDs or case-sensitive globs such as `com.jetbrains.*`, added from running apps, from an app in `/Applications`, or by hand (⌘N). Legacy `exclude` entries are shown and can be removed. Delete removes the selection; ⌘Z undoes. Whitelisted apps are never quit, updated or relaunched.
- **Run** offers **Preview (Dry Run)** (⇧⌘P) and **Update Now…** (⇧⌘U), which previews first, then asks for confirmation listing the apps that will be gracefully quit and relaunched; the apply run is limited to exactly those apps with `--only`. **History** shows `status` and `runs/*.json` read-only. ⌘R refreshes the current pane; ⌘1–⌘4 switch panes.
- **Settings › Behavior** edits `hour`, `timezone` (searchable picker), `quit_timeout_seconds`, `restart_current` and `restart_unmanaged`. Every other key in the config file (`apps`, `sparkle_cli`, …) is preserved, and a file that does not parse is never overwritten.
- **Settings › Engine** holds app-only preferences, stored in the app's user defaults (`co.kwon.daybreak`), never in the engine config: the Python interpreter, an engine checkout path, and the state folder passed as `--state-dir` (default `~/Library/Application Support/Daybreak`; keep it the same as your scheduled job's).

The engine is taken from the app bundle's Resources first, then from the checkout path in Settings. Python 3.11+ is found at `/opt/homebrew/bin`, `/usr/local/bin` or `/usr/bin`, unless an interpreter is set in Settings. The app creates no LaunchAgents or schedules and requests no extra permissions.

**Release builds.** The version comes from `[project] version` in `pyproject.toml`. `scripts/build-app.sh` builds arm64 + x86_64 slices of the app and `appbridge`, signs the helper and then the bundle (no `--deep`) with the hardened runtime, and zips the result into `.build/dist/`:

| Variable | Effect |
| --- | --- |
| `CODESIGN_IDENTITY` | Signing identity, e.g. `Developer ID Application: Name (TEAMID)`. Unset: ad-hoc (local use only) |
| `NOTARY_PROFILE` | `notarytool` keychain profile (`xcrun notarytool store-credentials`). With a Developer ID identity: notarize, staple, re-zip and check with `spctl` |
| `ARCHS` | Architectures to build (default `arm64 x86_64`) |

The icon is generated by `swift scripts/make-icon.swift app/Resources/AppIcon.icns`; the `.icns` is committed, so builds do not regenerate it. For QA, the app accepts `--pane running|whitelist|run|history`, `--appearance light|dark`, `--preview` (dry run on launch), `--settings [behavior|engine]` and `--snapshot DIR` (renders its own windows to PNGs, then quits). None of these can apply updates.

## Configuration and extending

See [configuration](docs/configuration.md), [architecture](docs/architecture.md), [troubleshooting](docs/troubleshooting.md), and [sources](docs/sources.md). Secrets, local configuration, inventories and reports must not be committed.

```sh
python3 -m unittest discover -s tests -v
python3 -m compileall -q daybreak tests
./scripts/build.sh
# Optional: launches and restarts ONLY a disposable test fixture app.
python3 tests/native_smoke.py --run
```

Tests cover safety failures, backend commands, DST, idempotency, locking and configuration. The opt-in macOS smoke test verifies real AppKit quit/relaunch/PID replacement using an app created for the test; it does not update your installed apps.
