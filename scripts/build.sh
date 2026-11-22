#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
swift build --package-path app -c release --product daybreak
bin_dir="$(swift build --package-path app -c release --show-bin-path)"
mkdir -p .build
cli="$(mktemp .build/daybreak.XXXXXX)"
trap 'if [ -f "$cli" ]; then unlink "$cli"; fi' EXIT
install -m 755 "$bin_dir/daybreak" "$cli"
mv -f "$cli" .build/daybreak
printf 'Built .build/daybreak\n'
