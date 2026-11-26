#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
swift build --package-path app -c release --product evergreen
bin_dir="$(swift build --package-path app -c release --show-bin-path)"
mkdir -p .build
cli="$(mktemp .build/evergreen.XXXXXX)"
trap 'if [ -f "$cli" ]; then unlink "$cli"; fi' EXIT
install -m 755 "$bin_dir/evergreen" "$cli"
mv -f "$cli" .build/evergreen
printf 'Built .build/evergreen\n'
