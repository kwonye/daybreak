---
name: verify-evergreen-ui
description: Verify Evergreen's native macOS UI after changes to the Updates pane, menu bar, Dock visibility, settings, or onboarding. Use for interactive checks and screenshots.
---

# Verify Evergreen UI

Start with the affected view and model under `app/Sources/EvergreenApp`. Build the signed local bundle with `./scripts/build-app.sh`. For runtime checks, use a copy of `.build/Evergreen.app` outside `/Applications`. Use a unique bundle ID and re-sign the copy when the test needs separate preferences. Point `-stateDirectory` at a temporary directory. Use `--config` with a temporary file for ordinary pane tests. For first-launch tests, launch the test executable with `CFFIXED_USER_HOME` set to a temporary directory so Foundation resolves the default config there. Keep production login-item and schedule preferences out of the test.

- For menu bar or Dock changes, hide the Dock icon in the test copy, close the main window, then open the menu bar popover. Exercise Open Evergreen and Settings from that state. Check that closing and reopening the window keeps the menu bar accessible.
- For Updates changes, check the initial loading and empty states, group headings, narrow-window alignment, disabled and busy controls, and any changed action. Exercise the one-hour automatic check cooldown separately from manual refresh. Use fixtures or cancel at confirmation when checking install interactions.
- For onboarding, begin with fresh preferences and launch without a pane or settings override. Complete onboarding and verify that the chosen preferences appear in Settings after relaunch. Check the login-item control in a disposable test context when its registration behavior is in scope.
- For layout-only evidence, run the test copy’s executable with `--snapshot DIR` and optionally `--appearance light` or `--appearance dark`. Snapshot mode suppresses automatic update checking. Use live interaction for menu bar and window behavior.

Report which paths were exercised on macOS and which were verified with fixtures or snapshots.
