#!/bin/sh
set -eu
cd "$(dirname "$0")/../.."

fixture="$(mktemp -d)"
trap 'rm -rf "$fixture"' EXIT
mkdir "$fixture/scripts"
cp scripts/version scripts/release-version "$fixture/scripts/"
cd "$fixture"
git init --quiet
git config user.name "Evergreen release test"
git config user.email "evergreen@example.invalid"
printf '0.1.0\n' > VERSION
git add VERSION scripts
git commit --quiet -m "Initial commit"

expect() {
    actual="$(sh scripts/release-version)"
    if [ "$actual" != "$1" ]; then
        printf 'Expected version "%s", got "%s"\n' "$1" "$actual" >&2
        exit 1
    fi
}

expect 0.1.0
git tag v0.1.0
expect ""
git commit --quiet --allow-empty -m "fix: handle an update"
git tag v9.0.0-beta.1
git tag v9x0x0
expect 0.1.1
git commit --quiet --allow-empty -m "feat(updates): add a package source"
git commit --quiet --allow-empty -m "Document the package source"
expect 0.2.0
git tag v0.2.0
git commit --quiet --allow-empty -m "refactor!: change the update contract"
expect 1.0.0
git tag v1.0.0
git commit --quiet --allow-empty -m "Replace the update contract" -m "BREAKING CHANGE: The old contract was removed."
expect 2.0.0
git tag v2.0.0
git checkout --quiet v1.0.0
expect ""
