# Troubleshooting

## Strict signature verification rejects Finder/resource metadata

Daybreak retains `codesign --verify --deep --strict`. If macOS reports “resource fork, Finder information, or similar detritus not allowed,” Daybreak blocks the update and emits a fixed diagnostic. It does not weaken the check, remove attributes, re-sign the app, or retry the installer.

Apple [QA1940](https://developer.apple.com/library/archive/qa/qa1940/_index.html) explains that extended attributes such as Finder information can cause this rejection, including metadata added through Finder. This error alone does not establish tampering, but it is not a successful signature verification either.

Inspect attribute **names** first. Any remediation should be a separate reviewed action on the specific application, preserve unrelated security metadata, and be followed by the unchanged strict verification and signing-identity checks. Broad attribute stripping, quarantine removal and ad-hoc re-signing are not Daybreak workarounds.

## A previous report says relaunch verification timed out

Do not automatically repeat the updater. It may already have installed successfully.

Daybreak verifies the primary executable rather than every new same-bundle helper. All original recorded PIDs must nevertheless be gone. Apps missing `CFBundleExecutable` can use a unique safe AppKit-observed executable, captured before updating. If these identities cannot be established, the outcome stays unresolved.

A read-only inspection can establish the current installed version, primary PID and launch time without rerunning an installer. Preserve the original report; distinguish that later verification from the original run. The daily gate remains consumed even if the report needs attention.

## Sparkle reports no update between probe and installation

Availability can change between steps. Installation exit 4 is reported as `no_update`; the app is still safely reopened and verified. This is not an installed-upgrade claim. Other nonzero installer exits are not treated as success.
