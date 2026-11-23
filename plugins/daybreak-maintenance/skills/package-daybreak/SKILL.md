---
name: package-daybreak
description: Build and verify Daybreak.app, its bundled Swift CLI, and its release ZIP. Use for local packaging, signing, notarization, or release workflow changes.
---

# Package Daybreak

Run from the repository root with Xcode and the macOS 26 SDK or newer. Follow `scripts/build-app.sh` for bundle assembly and `.github/workflows/release.yml` for release signing and publication. Read the artifact version with `./scripts/version`.

1. Run `swift test --package-path app` and `./scripts/build-app.sh`. The build produces an ad-hoc-signed `.build/Daybreak.app` and `.build/dist/Daybreak-<version>.zip` by default.
2. Run `codesign --verify --deep --strict --verbose=2 .build/Daybreak.app`. Check `lipo -archs .build/Daybreak.app/Contents/MacOS/Daybreak` for arm64 and x86_64 and `xcrun vtool -show-build .build/Daybreak.app/Contents/MacOS/Daybreak` for the SDK version.
3. Check the packaged CLI with `env -i PATH=/usr/bin:/bin .build/Daybreak.app/Contents/Helpers/daybreak status --state-dir "$(mktemp -d)"`. Check the ZIP with `unzip -t` using its exact versioned path.
4. For a requested distribution build, use the existing Developer ID signing identity and configured notary profile. Verify the stapled result with `xcrun stapler validate .build/Daybreak.app`. Keep signing credentials in the configured keychain or CI secrets.

Use the packaged output for local QA. Replacing the installed copy or pushing a release tag changes the user’s machine or publishes a release, so keep those actions within the user’s requested scope. When replacing an installed bundle, preserve its bundle ID and leave its preferences, config, and state in place.
