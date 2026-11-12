#!/bin/sh
# Builds .build/Daybreak.app (universal arm64 + x86_64) with the Python engine and the appbridge
# helper bundled, signs it with the hardened runtime, and writes .build/dist/Daybreak-<version>.zip.
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
APP="$ROOT/.build/Daybreak.app"
DIST="$ROOT/.build/dist"
WORK="$ROOT/.build/app-build"
ARCHS="${ARCHS:-arm64 x86_64}"
IDENTITY="${CODESIGN_IDENTITY:--}"
MIN_MACOS=14.0

# Single version source: [project] version in pyproject.toml.
VERSION="$(awk '
    /^\[/ { in_project = ($0 == "[project]") }
    in_project && /^version[[:space:]]*=/ { gsub(/^version[[:space:]]*=[[:space:]]*"|".*$/, ""); print; exit }
' pyproject.toml)"
if ! printf '%s' "$VERSION" | grep -Eq '^[0-9]+(\.[0-9]+){0,2}$'; then
    printf 'error: pyproject.toml [project] version "%s" is not a valid bundle version\n' "$VERSION" >&2
    exit 1
fi

rm -rf "$WORK"
mkdir -p "$WORK"

# appbridge: one slice per architecture, then lipo.
set --
for arch in $ARCHS; do
    xcrun swiftc -O -target "$arch-apple-macos$MIN_MACOS" native/AppBridge.swift -o "$WORK/appbridge-$arch"
    set -- "$@" "$WORK/appbridge-$arch"
done
lipo -create "$@" -output "$WORK/appbridge"

# App: SwiftPM multi-arch release build.
set --
for arch in $ARCHS; do set -- "$@" --arch "$arch"; done
(cd app && swift build -c release --product DaybreakApp "$@")
BIN_DIR="$(cd app && swift build -c release "$@" --show-bin-path)"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources/daybreak"
cp "$BIN_DIR/DaybreakApp" "$APP/Contents/MacOS/Daybreak"
cp "$WORK/appbridge" "$APP/Contents/Resources/appbridge"
cp app/Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
# Engine sources only: no caches or bytecode (the bundle is sealed; the app runs python -B).
for file in daybreak/*.py; do
    cp "$file" "$APP/Contents/Resources/daybreak/"
done

YEAR="$(date +%Y)"
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key><string>en</string>
    <key>CFBundleDisplayName</key><string>Daybreak</string>
    <key>CFBundleExecutable</key><string>Daybreak</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>CFBundleIdentifier</key><string>co.kwon.daybreak</string>
    <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
    <key>CFBundleName</key><string>Daybreak</string>
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
codesign "$@" --identifier co.kwon.daybreak.appbridge "$APP/Contents/Resources/appbridge"
codesign "$@" "$APP"
codesign --verify --strict --verbose=1 "$APP"

for binary in "$APP/Contents/MacOS/Daybreak" "$APP/Contents/Resources/appbridge"; do
    printf '%s: %s\n' "$(basename "$binary")" "$(lipo -archs "$binary")"
done

mkdir -p "$DIST"
ZIP="$DIST/Daybreak-$VERSION.zip"
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
