# Configuration

JSON, stored outside the repository. Unknown updater families are never treated as APIs.

```json
{
  "timezone": "America/Los_Angeles",
  "hour": 8,
  "quit_timeout_seconds": 60,
  "restart_current": true,
  "restart_unmanaged": true,
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

`whitelist` is a list of apps Daybreak always skips: never checked, updated, quit or relaunched, and never probed for a backend (dry-run or apply). Each entry is an exact bundle ID or a case-sensitive shell-style glob (`fnmatch`), e.g. `com.jetbrains.*`. Matching apps report status `excluded` with detail `Whitelisted by configuration`. Entries must be non-empty strings.

`exclude` is a legacy alias and still works; the effective skip list is the union of `whitelist` and `exclude`. The whitelist can only add skips: built-in protected apps stay protected (detail `Protected host/system app`).

`run --skip BUNDLE_ID_OR_PATTERN` (repeatable) adds entries for that run only and is not persisted. The whitelist wins over `--only`. With `--config`, `inventory` adds boolean `whitelisted` and `protected` fields to each app.

Only set Docker's flag true after accepting container/VM/Kubernetes interruption. No Docker restart occurs otherwise, even through restart-only fallback.

Sparkle CLI is optional and not installed by Daybreak. Build it from the official Sparkle project per its documentation using a distinct bundle identifier. Merely containing Sparkle does not mean a host's custom updater delegates/feed can be reproduced externally. Do not override feed URLs to make a host work.

Chrome auto-discovers the existing user updater under `~/Library/Application Support/Google/GoogleUpdater/Current/`. Only one helper is selected; product and existence-checker path must match. You may configure an absolute `executable` for a supported user-scope helper; the corresponding updater must already exist. Do not point this at a system-scope helper.

Explicit backend names: `sparkle`, `homebrew`, `app-store`, `docker`, `google`, `command`, `restart-only`. Homebrew's optional `cask` must match the already-managed path; it cannot adopt an unmanaged app.

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
- Preserve the signing team and bundle ID. New permissions, new terms, account login, major upgrades and privileged installers need their own handling. Daybreak does not automatically approve them.

App-specific updaters that require the host to remain running do not fit this command adapter. Implement a reviewed backend with explicit lifecycle semantics instead.
