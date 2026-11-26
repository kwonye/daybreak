---
name: verify-evergreen-updaters
description: Diagnose or verify Evergreen application and macOS update behavior, including availability checks, Update All, Mac App Store installation, app relaunch, and scheduled CLI runs.
---

# Verify Evergreen updaters

Start in `app/Sources/EvergreenKit`. Follow the update from inventory and classification through `UpdateCatalog.swift` and `UpdateBackends.swift` to `UpdateCoordinator.swift`. For Mac App Store behavior, inspect `NativeStoreUpdate.swift`, `StoreBundleInstaller.swift`, and the bridge and installer targets. For scheduled runs, include `NativeState.swift` and the app scheduler.

- Separate discovery, availability, installation, and verification when diagnosing a failure. Identify the exact app copy and what the updater returned. Keep check-only and manual actions usable when a direct install is unavailable.
- Preserve protected-app and whitelist behavior, bundle and publisher verification, graceful termination, and fresh primary-process verification. Treat installation timeouts as uncertain outcomes and avoid automatically retrying an install that could still be running.
- Keep Mac App Store installs gated by the user’s opt-in and by macOS authorization. For batch changes, verify that eligible apps go through the same install path as individual updates and that per-app failures reach the user.
- Run `swift test --package-path app`. Use `DAYBREAK_INTEGRATION=1 swift test --package-path app --filter EngineIntegrationTests` for read-only inventory and CLI preview checks on the host. Use `DAYBREAK_NATIVE_SMOKE=1 swift test --package-path app --filter NativeLifecycleSmoke` in a graphical macOS session for disposable app lifecycle coverage.

Use fixture apps and stub updater responses to verify install failures, signature mismatches, and relaunch behavior. Keep real app installs and OS updates within the scope authorized by the user. Redact local paths, account details, and identifying inventory from public reports.
