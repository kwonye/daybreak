#!/bin/sh
# Package Sparkle for Evergreen and build its separate external updater from pinned source.
set -eu

CACHE="$1"
ARCHITECTURES="$2"
MIN_MACOS="$3"
IDENTITY="$4"
DESTINATION="$5"
RESOURCES="$6"
FRAMEWORKS="$7"
REVISION=ab7d71291238df6e0492143b120c9b696a35f603 # Sparkle 2.10.1
SOURCE="$CACHE/$REVISION"
PRODUCTS="$CACHE/products-$REVISION"

mkdir -p "$CACHE"
if [ ! -d "$SOURCE/.git" ]; then
    TEMP="$(mktemp -d "$CACHE/source.XXXXXX")"
    trap 'rm -rf "$TEMP"' EXIT HUP INT TERM
    git -C "$TEMP" init -q
    git -C "$TEMP" fetch -q --depth 1 https://github.com/sparkle-project/Sparkle.git "$REVISION"
    git -C "$TEMP" checkout -q --detach FETCH_HEAD
    mv "$TEMP" "$SOURCE"
    trap - EXIT HUP INT TERM
fi
test "$(git -C "$SOURCE" rev-parse HEAD)" = "$REVISION"
xcodebuild -quiet -project "$SOURCE/Sparkle.xcodeproj" -target sparkle-cli -configuration Release \
    "ARCHS=$ARCHITECTURES" ONLY_ACTIVE_ARCH=NO CODE_SIGNING_ALLOWED=NO \
    "MACOSX_DEPLOYMENT_TARGET=$MIN_MACOS" "SYMROOT=$PRODUCTS"

HELPER="$DESTINATION/sparkle.app"
ditto "$PRODUCTS/Release/sparkle.app" "$HELPER"
/usr/libexec/PlistBuddy -c 'Set CFBundleIdentifier co.kwon.evergreen.sparkle' "$HELPER/Contents/Info.plist"
cp "$SOURCE/LICENSE" "$RESOURCES/Sparkle-LICENSE.txt"

if [ "$IDENTITY" = "-" ]; then
    # Ad-hoc code has no team ID for library validation.
    set -- --force --sign -
else
    set -- --force --options runtime --timestamp --sign "$IDENTITY"
fi
sign_framework() {
    framework="$1/Versions/Current"
    shift
    codesign "$@" "$framework/Autoupdate"
    codesign "$@" "$framework/Updater.app"
    for service in "$framework"/XPCServices/*.xpc; do
        if [ -d "$service" ]; then codesign "$@" "$service"; fi
    done
    codesign "$@" "$framework"
}

# SwiftPM downloads the universal XCFramework linked by EvergreenApp.
mkdir -p "$FRAMEWORKS"
ditto app/.build/artifacts/app/Sparkle/Sparkle.xcframework/macos-arm64_x86_64/Sparkle.framework \
    "$FRAMEWORKS/Sparkle.framework"
sign_framework "$FRAMEWORKS/Sparkle.framework" "$@"
sign_framework "$HELPER/Contents/Frameworks/Sparkle.framework" "$@"
codesign "$@" "$HELPER"
codesign --verify --deep --strict "$HELPER"
USAGE="$("$HELPER/Contents/MacOS/sparkle" 2>&1 || :)"
printf '%s\n' "$USAGE" | grep -q '^Usage: .*bundle'
