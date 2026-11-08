#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
mkdir -p .build
xcrun swiftc -O native/AppBridge.swift -o .build/appbridge
printf 'Built .build/appbridge\n'
