# Contributing to Evergreen

For using the app, start with the [README](README.md). This guide covers building, changing, testing, and releasing it.

## Build and run

Use a Mac with Xcode 26 or later and the macOS 26 SDK or newer. Keep the app’s deployment target at macOS 14; gate newer APIs with availability checks.

```sh
git clone https://github.com/kwonye/evergreen.git
cd evergreen
./scripts/build-app.sh
open .build/Evergreen.app
```

The build creates a universal app and `.build/dist/Evergreen-<version>.zip`. The default ad-hoc build is for local use, not distribution. Use the packaged app to verify Liquid Glass on macOS 26 or newer; the build records the linked SDK so macOS enables that appearance.

For a faster development loop, run `swift run --package-path app EvergreenApp`. To build just the engine and CLI in a checkout, use `./scripts/build.sh`.

## Where to make changes

- `app/Sources/EvergreenApp`: SwiftUI, onboarding, preferences, menu bar, and scheduling.
- `app/Sources/EvergreenKit`: discovery, updater selection, version and relaunch verification, and local reports.
- `app/Sources/EvergreenCLI`: the CLI, which uses the same engine, configuration, and reports as the app.
- `app/Sources/EvergreenStoreBridge` and `app/Sources/EvergreenStoreInstaller`: App Store integration and its installer. Preserve the user opt-in and macOS authorization.
- `app/Tests/EvergreenKitTests`: engine and platform tests.

See [architecture](docs/architecture.md), the [configuration contract](docs/configuration.md), the [CLI contract](docs/cli.md), and [upstream references](docs/sources.md). Check [AGENTS.md](AGENTS.md) for repo-specific guidance and QA skills.

When changing settings, preserve untouched keys and don’t overwrite a configuration file that fails to parse. Keep existing CLI automation and Daybreak compatibility working. Never commit credentials, private configuration, app inventories, or reports.

## Test changes

```sh
swift test --package-path app
DAYBREAK_INTEGRATION=1 swift test --package-path app
# Optional: launches and restarts only a disposable test fixture app.
DAYBREAK_NATIVE_SMOKE=1 swift test --package-path app --filter NativeLifecycleSmoke
```

Run the first command for Swift changes. Tests cover failure handling, backend commands, daylight saving time, idempotency, locks, and configuration. The integration flag adds read-only engine checks. The native smoke test verifies real AppKit quit/relaunch and process replacement against a fixture, not your installed apps. Use isolated config/state directories for CLI checks. Building and testing do not install updates or schedule jobs.

## Updater backends

| Backend | Behavior | Prerequisites / limits |
| --- | --- | --- |
| Chrome | Uses Google's documented `ksadmin --install --productid com.google.Chrome --user-store` compatibility API, then relaunches | Existing user-scope Google updater and exact Chrome registration must match. No updater installation, system scope, or update-all command |
| Sparkle | Official external Sparkle CLI probes, installs, then coordinator relaunches | Supply `sparkle_cli`; app must expose a compatible feed/configuration. No install-time feed overrides, signature bypass, automatic major-upgrade opt-in, or internal Autoupdate/ShipIt invocation |
| Homebrew cask | Checks/upgrades one existing managed cask | Exact `/Applications` app path must match installed JSON cask metadata. No automatic adoption, reinstall, bulk or greedy updates. Legacy Ruby metadata/custom app directories require an explicit adapter |
| Mac App Store | Optional `mas outdated` / `mas update ID` | User-installed `mas`, App Store receipt, explicit numeric `app_id`, signed-in account. `mas` is third-party, not an Apple API. It may need user interaction; no sudo or automatic dependency install |
| Docker Desktop | Native `docker desktop update --quiet`, fresh-process check, then engine health check | Explicit `allow_workload_interruption: true`. Containers, Kubernetes and VM workloads can stop. Docker's command has no stable machine-readable availability response |
| Electron / Squirrel / unknown | Graceful restart to apply a vendor-staged update | No generic external update API. Latest-release availability is unknown unless a supported command adapter is configured |

The Apps pane also checks Apple’s public App Store catalog, ChatGPT’s feed for the installed architecture, vendor feeds, and GitHub releases. Electron apps can use a bundled or [configured HTTPS feed](docs/configuration.md#electron-update-feeds). For public Homebrew matches, require the bundle ID and filename to identify the installed app. Offer direct installation only when the release download and installed publisher can be verified.

## Safety and honest verification

- Takes one initial running-app snapshot; never starts an app that was not running. If it stops before its turn, it is skipped.
- Requests normal AppKit termination and waits. Save prompts, quit refusals and timeouts defer the app. **Never force-quits, sends kill signals, dismisses save dialogs, or reboots.**
- Graceful quit is **not a guarantee against data loss**. Browser forms, incognito sessions, meetings and app-specific state may still be lost. Reopening a browser does not guarantee tab/session restoration. Configure exclusions if necessary.
- Updates must preserve a valid developer signing team and bundle ID. Invalid signatures block relaunch; changing publishers requires manual review.
- After an installer failure, only requests recovery launch if the app is absent and its signature still verifies. On installer timeout, completion is uncertain and no automatic reopen/retry is attempted.
- Success requires a fresh primary PID/start time, verified executable path, current bundle version and fingerprint. New auxiliary processes sharing the bundle ID are not mistaken for the main executable, but any original PID still present blocks verification. Command success alone is not enough. This verifies **“relaunched installed version”**, not a direct measurement of arbitrary in-memory application versions, nor proof that no newer release exists.
- Isolates each app's failure, runs sequentially, locks overlapping jobs, writes private JSON reports, and suppresses arbitrary updater stdout/stderr from reports to reduce accidental sensitive logging.

When a vendor omits `CFBundleExecutable`, Evergreen uses only a unique executable observed by macOS inside that bundle’s `Contents/MacOS` directory. It does not guess from directory contents, accept escaping symlinks, or silently switch to a helper after updating.

Sparkle exit 4 during installation means no update is available at that point. Evergreen still verifies the signature and relaunch, reports `checked_and_relaunched`, and does not claim an upgrade.

The current process may already be older than its bundle on disk. Evergreen compares mapped executable inode with current disk inode when `lsof` can establish that fact. Lack of that signal is not proof of freshness; the default fresh-process relaunch handles that case.

## Packaging and signing

The version comes from the root `VERSION` file. `scripts/build-app.sh` builds arm64 and x86_64 slices of the app and its native CLI, signs the bundled helpers and then the app with the hardened runtime for Developer ID builds, and zips the result into `.build/dist/`:

| Variable | Effect |
| --- | --- |
| `CODESIGN_IDENTITY` | Signing identity, e.g. `Developer ID Application: Name (TEAMID)`. Unset: ad-hoc (local use only) |
| `NOTARY_PROFILE` | `notarytool` keychain profile (`xcrun notarytool store-credentials`). With a Developer ID identity: notarize, staple, re-zip and check with `spctl` |
| `SPARKLE_FEED_URL` | HTTPS appcast URL to enable Evergreen self-updates |
| `ARCHS` | Architectures to build (default `arm64 x86_64`) |

The icon is generated by `swift scripts/make-icon.swift app/Resources/AppIcon.icns`; the `.icns` is committed, so builds do not regenerate it. For QA, the app accepts `--pane updates|running|whitelist|history`, `--appearance light|dark`, `--settings [general|behavior]` and `--snapshot DIR` (renders its own windows to PNGs, then quits). None of these can apply updates.

## CI and releases

CI uses Xcode 27.2. The Release workflow runs Swift tests, builds the universal app and CLI, verifies the bundle, smoke-tests the bundled CLI, and uploads the release ZIP. Pull requests and pushes to main trigger an ad-hoc signed build when code, build inputs, examples, or workflows change. Use Actions → Release → Run workflow to build manually.

Push a tag matching the root `VERSION` file (for example, `v0.1.0`) to build with Developer ID signing, notarize the app, and publish the verified ZIP and signed Sparkle appcast together to GitHub Releases. Tagged builds require the Apple signing and notarization secrets listed in the [Release workflow](.github/workflows/release.yml), plus `SPARKLE_PRIVATE_KEY` matching the public key in `app/Resources/SparklePublicKey.txt`. The macOS bundle checks the latest stable release’s `appcast.xml` and verifies both the feed and the ZIP. Local builds omit self-updates unless built with an explicit HTTPS `SPARKLE_FEED_URL`.
