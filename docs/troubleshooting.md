# Troubleshooting

## macOS blocked Evergreen from modifying an app

In Evergreen, open **Settings → Updates → App Management**. Click **Open App Management** to open **System Settings → Privacy & Security → App Management**. Drag the Evergreen icon from Evergreen into the list and turn on its switch. You can also use the **+** button in System Settings to select Evergreen. Follow any macOS prompt, then retry the update.

## Strict signature verification rejects Finder/resource metadata

Evergreen uses `codesign --verify --deep --strict`. If macOS rejects a bundle because Finder recorded default folder icon positions, Evergreen clears those positions on a temporary copy and runs the same strict check again. The installed app keeps its metadata. A copy that still fails verification blocks the update.

Apple [QA1940](https://developer.apple.com/library/archive/qa/qa1940/_index.html) explains that extended attributes such as Finder information can cause this rejection, including metadata added through Finder. This error alone does not establish tampering, but it is not a successful signature verification either.

Inspect attribute **names** first. Any remediation should be a separate reviewed action on the specific application, preserve unrelated security metadata, and be followed by the unchanged strict verification and signing-identity checks. Broad attribute stripping, quarantine removal and ad-hoc re-signing are not Evergreen workarounds.

## A previous report says relaunch verification timed out

Do not automatically repeat the updater. It may already have installed successfully.

Evergreen verifies the primary executable rather than every new same-bundle helper. All original recorded PIDs must nevertheless be gone. Apps missing `CFBundleExecutable` can use a unique safe AppKit-observed executable, captured before updating. If these identities cannot be established, the outcome stays unresolved.

A read-only inspection can establish the current installed version, primary PID and launch time without rerunning an installer. Preserve the original report; distinguish that later verification from the original run. The daily gate remains consumed even if the report needs attention.

## Sparkle reports no update between probe and installation

Availability can change between steps. Installation exit 4 is reported as `no_update`; the app is still safely reopened and verified. This is not an installed-upgrade claim. Other nonzero installer exits are not treated as success.
