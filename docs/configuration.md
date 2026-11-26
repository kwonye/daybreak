# Configuration

JSON, stored outside the repository. Unknown updater families are never treated as APIs.

```json
{
  "timezone": "America/Los_Angeles",
  "hour": 8,
  "minute": 0,
  "schedule_cadence": "daily",
  "schedule_weekday": 2,
  "automatic_runs": false,
  "schedule_scope": "apps",
  "quit_timeout_seconds": 60,
  "restart_current": true,
  "restart_unmanaged": false,
  "direct_app_store_updates": false,
  "whitelist": ["com.example.DoNotInterrupt", "com.jetbrains.*"],
  "sparkle_cli": "/absolute/path/to/sparkle.app/Contents/MacOS/sparkle",
  "apps": {
    "com.docker.docker": {
      "backend": "docker",
      "allow_workload_interruption": false
    },
    "com.example.StoreApp": {
      "backend": "app-store",
      "app_id": "123456789"
    },
    "com.example.SparkleApp": {
      "backend": "sparkle"
    }
  }
}
```

## Whitelist

`whitelist` is a list of apps Evergreen always skips: never checked, updated, quit or relaunched, and never probed for a backend (preview or update). Each entry is an exact bundle ID or a case-sensitive shell-style glob (`fnmatch`), e.g. `com.jetbrains.*`. Matching apps report status `excluded` with detail `Whitelisted by configuration`. Entries must be non-empty strings.

`exclude` is a legacy alias and still works; the effective skip list is the union of `whitelist` and `exclude`. The whitelist can only add skips: built-in protected apps keep their protection.

`run --skip BUNDLE_ID_OR_PATTERN` (repeatable) adds entries for that run only and is not persisted. The whitelist wins over `--only`. With `--config`, `inventory` adds boolean `whitelisted` and `protected` fields to each app.

Only set Docker's flag true after accepting container/VM/Kubernetes interruption. No Docker restart occurs otherwise, even through restart-only fallback.

Sparkle CLI is optional and not installed by Evergreen. Build it from the official Sparkle project per its documentation using a distinct bundle identifier. Merely containing Sparkle does not mean a host's custom updater delegates/feed can be reproduced externally. Do not override feed URLs to make a host work.

Chrome auto-discovers the existing user updater under `~/Library/Application Support/Google/GoogleUpdater/Current/`. Only one helper is selected; product and existence-checker path must match. You may configure an absolute `executable` for a supported user-scope helper; the corresponding updater must already exist. Do not point this at a system-scope helper.

Explicit backend names: `sparkle`, `homebrew`, `app-store`, `docker`, `google`, `command`, `restart-only`. Homebrew's optional `cask` must match the already-managed path; it cannot adopt an unmanaged app.

## Update schedule

The due gate uses the configured wall-clock `hour`, `minute`, and `timezone`. `schedule_cadence` accepts `daily`, `weekdays` (Monday through Friday), or `weekly`. For `weekly`, `schedule_weekday` uses 1 for Sunday through 7 for Saturday and defaults to Monday.

`automatic_runs` opts in to scheduled updates. `schedule_scope` accepts `apps` (the default), `brew`, or `both`. Apps covers eligible running apps and verified releases for installed apps, including closed apps. Brew covers eligible installed Homebrew formulae and casks. Evergreen shows the Brew scope choices when it finds the Homebrew CLI.

In **Settings → Schedule**, enable **Run in background when Evergreen is closed** to register a macOS login-session agent. macOS may ask for approval in Login Items. The agent runs while the user is signed in, even after quitting Evergreen. Automatic runs start within 30 minutes of the scheduled time. After that, Evergreen checks for pending updates in the selected scope and offers **Run Updates Now** if it can apply any. Enable missed-run notifications to get the same action in Notification Center.

CLI invocations using `--due` use the same scope and cadence regardless of the desktop opt-in. A late CLI invocation can run on the same eligible date. Use the same state directory so the CLI, app and background agent share the date gate.

## Electron update feeds

Evergreen reads public GitHub and generic HTTPS feeds from Electron apps’ bundled `app-update.yml`. It can install ZIPs and disk images when the feed identifies a compatible release and supplies a checksum.

For an app that configures its updater at runtime, map its bundle ID to the exact HTTPS manifest URL in `electron_update_feeds`. This supports electron-builder YAML, including custom channel manifests, and Squirrel.Mac JSON entries that provide a release version and SHA-256 digest.

```json
{
  "electron_update_feeds": {
    "com.example.desktop": "https://updates.example.com/desktop/latest-mac.yml"
  }
}
```

Feeds that require app-specific authentication or a staged rollout remain available through the app’s own updater.

## Mac App Store

The Apps pane checks the public App Store catalog directly. It shows the newest version the catalog can identify for the installed Mac app. What the App Store offers can also depend on the signed-in account and rollout.

`direct_app_store_updates` is off by default. It enables individually initiated updates in the Apps pane for eligible signed copies in `/Applications`. Evergreen uses the system's private commerce interfaces for downloads. If local installation is required, macOS can authorize a one-shot helper that verifies the replacement and its App Store receipt before installing it. Use the App Store for macOS versions or packages that the direct path cannot handle.

## Supported command adapter

For an app that has its own documented update CLI:

```json
{
  "apps": {
    "com.example.Editor": {
      "backend": "command",
      "check": ["/absolute/path/to/adapter", "check", "{app_path}"],
      "apply": ["/absolute/path/to/adapter", "apply", "{app_path}"]
    }
  }
}
```

- `check` must emit a JSON object with `state`: `available`, `current`, or `unknown`.
- An `available` response must include `target_version` matching the expected bundle short version or build exactly.
- `apply` runs with the application already gracefully closed and must synchronously complete installation. Exit nonzero on failure. It must not return while an installer continues asynchronously.
- Only literal `{app_path}` and `{bundle_id}` substitution occurs. There is no shell, eval, remote script loading, or environment-secret expansion.
- Adapters are trusted local code and can do what their executables can do. Review them; do not accept adapter configuration from feeds or untrusted documents.
- Preserve the signing team and bundle ID. New permissions, new terms, account login, major upgrades and privileged installers need their own handling. Evergreen does not automatically approve them.

App-specific updaters that require the host to remain running do not fit this command adapter. Implement a reviewed backend with explicit lifecycle semantics instead.
