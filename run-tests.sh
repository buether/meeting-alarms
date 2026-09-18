#!/bin/bash
# Builds and runs the unit tests. They cover the pure selection logic, so they
# need no calendar, no permissions and no window server.
set -euo pipefail

REPO="$(cd "$(dirname "$0")" && pwd)"
TARGET="$(uname -m)-apple-macos14.0"

mkdir -p "$REPO/build"
# Every source but main.swift, whose top-level code the test binary replaces.
sources=()
for source in "$REPO"/src/*.swift; do
  [ "$(basename "$source")" = "main.swift" ] || sources+=("$source")
done

swiftc -target "$TARGET" -O -suppress-warnings \
  -o "$REPO/build/meeting-alarm-tests" "${sources[@]}" "$REPO/tests/main.swift"
exec "$REPO/build/meeting-alarm-tests"
