#!/bin/sh
# Sign a packaged release and generate the appcast asset served by GitHub Releases.
set -eu
cd "$(dirname "$0")/.."
REPOSITORY_URL="$1"
VERSION="$(./scripts/version)"
ASSET="Evergreen-$VERSION.zip"
DOWNLOAD_URL="$REPOSITORY_URL/releases/download/v$VERSION"
SPARKLE_VERSION=2.10.1
TOOLS=".build/sparkle/tools-$SPARKLE_VERSION"
TARBALL="Sparkle-$SPARKLE_VERSION.tar.xz"
SHA256=1a856d2a9edb8e628de88121d7be04cf0e2167f8641650b78fca00b14244cf27

mkdir -p "$TOOLS"
if [ ! -f "$TOOLS/$TARBALL" ]; then
    curl --fail --silent --show-error --location \
        "https://github.com/sparkle-project/Sparkle/releases/download/$SPARKLE_VERSION/$TARBALL" \
        --output "$TOOLS/$TARBALL"
fi
printf '%s  %s\n' "$SHA256" "$TOOLS/$TARBALL" | shasum -a 256 --check
tar -xf "$TOOLS/$TARBALL" -C "$TOOLS" bin/generate_appcast bin/sign_update

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
cp ".build/dist/$ASSET" "$WORK/"
with_signing_key() {
    tool="$1"
    shift
    if [ -n "${SPARKLE_PRIVATE_KEY:-}" ]; then
        printf '%s\n' "$SPARKLE_PRIVATE_KEY" | "$tool" --ed-key-file - "$@"
    else
        "$tool" --account co.kwon.evergreen "$@"
    fi
}

with_signing_key "$TOOLS/bin/generate_appcast" --maximum-deltas 0 --download-url-prefix "$DOWNLOAD_URL/" \
    --link "$REPOSITORY_URL/releases/tag/v$VERSION" "$WORK"

FEED="$WORK/appcast.xml"
ITEM='/rss/channel/item'
ENCLOSURE="$ITEM/enclosure"
test "$(xmllint --xpath "string($ITEM/*[local-name()='version'])" "$FEED")" = "$VERSION"
test "$(xmllint --xpath "string($ENCLOSURE/@url)" "$FEED")" = "$DOWNLOAD_URL/$ASSET"
test "$(xmllint --xpath "string($ENCLOSURE/@length)" "$FEED")" = "$(stat -f %z "$WORK/$ASSET")"
SIGNATURE="$(xmllint --xpath "string($ENCLOSURE/@*[local-name()='edSignature'])" "$FEED")"
test -n "$SIGNATURE"
with_signing_key "$TOOLS/bin/sign_update" --verify "$WORK/$ASSET" "$SIGNATURE"
with_signing_key "$TOOLS/bin/sign_update" --verify "$FEED"
cp "$FEED" .build/dist/appcast.xml
