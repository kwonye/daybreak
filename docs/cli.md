# Evergreen command-line guide

## Preview and apply

For an installed copy, use `/Applications/Evergreen.app/Contents/Helpers/evergreen` in place of `./scripts/evergreen`. The checkout examples assume you are in the repo root; see [build instructions](../CONTRIBUTING.md#build-and-run) if needed.

```sh
./scripts/evergreen inventory
./scripts/evergreen run
```

Preview reads app/process metadata and local installed-cask metadata. It **does not** invoke an updater, make network requests, quit/relaunch apps, or write run state. If the environment cannot enumerate running apps, it fails instead of reporting an empty successful run.

To configure, copy `examples/config.example.json` outside the repository, edit it, then preview again:

```sh
mkdir -p "$HOME/.config/evergreen"
cp examples/config.example.json "$HOME/.config/evergreen/config.json"
./scripts/evergreen run --config "$HOME/.config/evergreen/config.json"
```

To allow Evergreen to quit, update, and relaunch eligible running apps:

```sh
./scripts/evergreen run --apply --config "$HOME/.config/evergreen/config.json"
```

Use `--only com.google.Chrome` (repeatable) to limit a run. Do not run as root. The process must run in the logged-in user's GUI session and have permission to enumerate/terminate apps. It does not request Accessibility access or change macOS permissions. Restricted execution environments may need their supported approval mechanism; do not work around access denials.

## Run from an external scheduler

If you use an external job, have it invoke Evergreen on the Mac:

```sh
/Applications/Evergreen.app/Contents/Helpers/evergreen run --apply --due \
  --config "$HOME/.config/evergreen/config.json"
```

If your job runs from a checkout, use the absolute path to `scripts/evergreen` instead. Keep the same config and state directory when switching commands.

The gate uses `America/Los_Angeles`, so DST follows Pacific wall time. By default it allows one run per local calendar date at or after 08:00. Settings can change the time and restrict eligible dates to weekdays or one day a week. A late same-day invocation catches up; it does not wake a sleeping Mac, run while logged out, or replay missed days. External jobs and automatic in-app runs share the gate when they use the same state folder.

The date is consumed **before work starts** to avoid repeated interruptions after a crash. Failures are not automatically retried that day. Inspect the report and use a manually targeted `--apply --only ...` without `--due` when safe. Preview leaves the schedule untouched. Keep one consistent state directory across triggers.

Evergreen does not create a LaunchAgent or an external job for you.

## Upgrading from Daybreak

If you upgraded from Daybreak, Evergreen uses your existing `~/.config/daybreak/config.json` and `~/Library/Application Support/Daybreak/` when their Evergreen counterparts are absent. The `scripts/daybreak` command and the bundled `daybreak` helper still work. Update any absolute app paths in your jobs if you rename the installed bundle to `Evergreen.app`. Evergreen imports app preferences on first launch. If you used Start at Login, enable it for Evergreen in Settings because macOS registers login items by app identity.

## Reports and exit codes

```sh
./scripts/evergreen status
```

Default private state: `~/Library/Application Support/Evergreen/`.

- `latest.json`: last actual run, including before/after versions and builds, primary PIDs, and updater outcome
- `runs/*.json`: last 30 runs
- `schedule.json`: daily gate; `run.lock`: overlap lock
- stdout: full JSON report (inventory includes local app paths; treat it as private)

Status values distinguish `updated_and_relaunched`, `checked_and_relaunched`, `restart_only_unverified`, `current`, `deferred`, `blocked`, `failed`, `uncertain`, `unsupported`, `skipped`, `excluded`, and preview `planned`.

Exit 0 means no attention state was reported (not “everything is latest”). Exit 2 means one or more apps need attention or have unverified update coverage. Exit 1 means setup/configuration/inventory failed. Preview may return 2 to expose blocked configuration such as Docker's missing workload opt-in.

See the [configuration reference](configuration.md) for all settings and [troubleshooting](troubleshooting.md) if a run needs attention.
