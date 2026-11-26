# Evergreen contributor guide

Evergreen is a native macOS SwiftUI app with a bundled Swift CLI. Both use the same engine in `EvergreenKit`. Build from the repository root on macOS with Xcode and the macOS 26 SDK or newer. Keep the macOS 14 deployment target and use availability checks for newer UI APIs.

## Where to work

- `app/Sources/EvergreenApp` owns the SwiftUI panes, AppKit window and menu bar integration, onboarding, settings, and scheduling.
- `app/Sources/EvergreenKit` owns application discovery, updater selection and verification, configuration, and local state. `EvergreenCLI` exposes the engine for automation.
- `EvergreenStoreBridge` and `EvergreenStoreInstaller` are the macOS App Store bridge and narrowly scoped installer. Preserve the opt-in and macOS authorization for direct App Store installs.
- `app/Tests/EvergreenKitTests` contains engine and platform tests. See [configuration](docs/configuration.md) for the JSON contract and [.github/workflows](.github/workflows) for the current CI and release commands.

## Develop and verify

- Run `swift test --package-path app` for Swift changes. Run `./scripts/build-app.sh` when changing the app bundle or verifying behavior in the packaged app.
- Keep existing JSON configuration and CLI automation working. Use an isolated config and state directory for CLI smoke checks, and preserve user settings when working with the installed app.
- Use the existing updater and verification paths for installs and relaunches. Keep update source details out of user-facing status and action copy. Use disposable fixtures to test actions that affect installed apps.
- For website tasks, use the Pomerado MCP before opening a browser.

## Repo plugins

The [Evergreen marketplace](.agents/plugins/marketplace.json) and [project config](.codex/config.toml) expose these skills in Codex for trusted checkouts.

| Plugin | Skills |
| --- | --- |
| Evergreen macOS QA | [Verify Evergreen UI](plugins/evergreen-macos-qa/skills/verify-evergreen-ui/SKILL.md) |
| Evergreen Maintenance | [Verify Evergreen updaters](plugins/evergreen-maintenance/skills/verify-evergreen-updaters/SKILL.md), [Package Evergreen](plugins/evergreen-maintenance/skills/package-evergreen/SKILL.md) |
