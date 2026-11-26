#!/bin/sh
# Builds .build/Evergreen.app (universal arm64 + x86_64) with the native CLI
# bundled, signs it with the hardened runtime, and writes .build/dist/Evergreen-<version>.zip.
# It never installs, launches, schedules or updates anything.
#
# Environment:
#   CODESIGN_IDENTITY  Signing identity, e.g. "Developer ID Application: Name (TEAMID)".
#                      Unset: ad-hoc signature (runs locally, not distributable).
#   NOTARY_PROFILE     notarytool keychain profile (xcrun notarytool store-credentials ...).
#   KEYCHAIN           Optional keychain file holding NOTARY_PROFILE (used by the release workflow).
#                      Set together with a Developer ID identity to notarize and staple.
#   ARCHS              Architectures to build (default: "arm64 x86_64").
set -eu
cd "$(dirname "$0")/.."
ROOT="$(pwd)"
APP="$ROOT/.build/Evergreen.app"
DIST="$ROOT/.build/dist"
ARCHS="${ARCHS:-arm64 x86_64}"
IDENTITY="${CODESIGN_IDENTITY:--}"
MIN_MACOS=14.0
MACOS_SDK="$(xcrun --sdk macosx --show-sdk-version)"
if [ "${MACOS_SDK%%.*}" -lt 26 ]; then
    printf 'error: Evergreen.app requires the macOS 26 SDK or newer (found %s)\n' "$MACOS_SDK" >&2
    exit 1
fi

VERSION="$(./scripts/version)"

# Some SwiftPM toolchains stamp the deployment target as the linked SDK.
# Set both explicitly so macOS enables Liquid Glass while keeping macOS 14 support.
set --
for arch in $ARCHS; do set -- "$@" --arch "$arch"; done
XCODE_MAJOR="$(xcodebuild -version | awk '/^Xcode / { split($2, v, "."); print v[1]; exit }')"
if [ "$XCODE_MAJOR" -lt 27 ]; then
    # Xcode 26's Swift Build passes these options to clang rather than ld.
    set -- "$@" -Xlinker "-Wl,-platform_version,macos,$MIN_MACOS,$MACOS_SDK"
else
    set -- "$@" -Xlinker -platform_version -Xlinker macos -Xlinker "$MIN_MACOS" -Xlinker "$MACOS_SDK"
fi
(cd app && swift build -c release --product EvergreenApp "$@" &&
    swift build -c release --product evergreen "$@" &&
    swift build -c release --product evergreen-store-installer "$@")
BIN_DIR="$(cd app && swift build -c release "$@" --show-bin-path)"

if ! xcrun vtool -show-build "$BIN_DIR/EvergreenApp" | awk '
    $1 == "sdk" { count++; split($2, version, "."); if (version[1] < 26) outdated = 1 }
    END { exit (!count || outdated) }
'; then
    printf 'error: Evergreen.app was not linked for Liquid Glass (macOS SDK 26+)\n' >&2
    exit 1
fi

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Helpers" "$APP/Contents/Resources"
cp "$BIN_DIR/EvergreenApp" "$APP/Contents/MacOS/Evergreen"
cp "$BIN_DIR/evergreen" "$APP/Contents/Helpers/evergreen"
ln -s evergreen "$APP/Contents/Helpers/daybreak"
cp "$BIN_DIR/evergreen-store-installer" "$APP/Contents/Helpers/evergreen-store-installer"
cp app/Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
sh scripts/build-sparkle.sh "$ROOT/.build/sparkle" "$ARCHS" "$MIN_MACOS" "$IDENTITY" \
    "$APP/Contents/Helpers" "$APP/Contents/Resources"
YEAR="$(date +%Y)"
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key><string>en</string>
    <key>CFBundleDisplayName</key><string>Evergreen</string>
    <key>CFBundleExecutable</key><string>Evergreen</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>CFBundleIdentifier</key><string>co.kwon.daybreak</string>
    <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
    <key>CFBundleName</key><string>Evergreen</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>$VERSION</string>
    <key>CFBundleVersion</key><string>$VERSION</string>
    <key>LSApplicationCategoryType</key><string>public.app-category.utilities</string>
    <key>LSMinimumSystemVersion</key><string>$MIN_MACOS</string>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSHumanReadableCopyright</key><string>Copyright © $YEAR Will Kwon.</string>
    <key>NSPrincipalClass</key><string>NSApplication</string>
    <key>NSSupportsAutomaticTermination</key><false/>
    <key>NSSupportsSuddenTermination</key><false/>
</dict>
</plist>
PLIST
plutil -lint "$APP/Contents/Info.plist" >/dev/null
printf 'APPL????' > "$APP/Contents/PkgInfo"

# Sign inside-out (no --deep): the helper first, then the bundle. Hardened runtime always;
# secure timestamps only with a real identity (ad-hoc signatures cannot be timestamped).
if [ "$IDENTITY" = "-" ]; then
    set -- --force --options runtime --sign -
else
    set -- --force --options runtime --timestamp --sign "$IDENTITY"
fi
codesign "$@" --identifier co.kwon.daybreak.cli "$APP/Contents/Helpers/evergreen"
codesign "$@" --identifier co.kwon.daybreak.store-installer "$APP/Contents/Helpers/evergreen-store-installer"
codesign "$@" "$APP"
codesign --verify --strict --verbose=1 "$APP"

for binary in "$APP/Contents/MacOS/Evergreen" "$APP/Contents/Helpers/evergreen" "$APP/Contents/Helpers/evergreen-store-installer"; do
    printf '%s: %s\n' "$(basename "$binary")" "$(lipo -archs "$binary")"
done

mkdir -p "$DIST"
ZIP="$DIST/Evergreen-$VERSION.zip"
rm -f "$ZIP"
ditto -c -k --sequesterRsrc --keepParent "$APP" "$ZIP"

if [ -n "${NOTARY_PROFILE:-}" ]; then
    if [ "$IDENTITY" = "-" ]; then
        printf 'error: NOTARY_PROFILE requires CODESIGN_IDENTITY (Developer ID Application)\n' >&2
        exit 1
    fi
    xcrun notarytool submit "$ZIP" --keychain-profile "$NOTARY_PROFILE" ${KEYCHAIN:+--keychain "$KEYCHAIN"} --wait
    xcrun stapler staple "$APP"
    xcrun stapler validate "$APP"
    rm -f "$ZIP"
    ditto -c -k --sequesterRsrc --keepParent "$APP" "$ZIP"
    spctl --assess --type execute --verbose "$APP"
fi

printf 'Built %s (version %s, signed: %s)\n' "$APP" "$VERSION" "$([ "$IDENTITY" = "-" ] && echo ad-hoc || echo "$IDENTITY")"
printf 'Archive %s\n' "$ZIP"
