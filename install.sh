#!/bin/bash
# Builds the signed app bundle, then hands off to `meeting-alarm install` to
# write and load the LaunchAgents. Safe to re-run; it only rebuilds the bundle
# when the sources changed.
set -euo pipefail

REPO="$(cd "$(dirname "$0")" && pwd)"
APP="$REPO/build/MeetingAlarm.app"
BIN="$APP/Contents/MacOS/meeting-alarm"
TARGET="$(uname -m)-apple-macos14.0"

command -v swiftc >/dev/null || { echo "swiftc is missing: xcode-select --install"; exit 1; }

needs_build() {
  [ -x "$BIN" ] || return 0
  [ "$REPO/app/Info.plist" -nt "$APP/Contents/Info.plist" ] && return 0
  for source in "$REPO"/src/*.swift; do
    [ "$source" -nt "$BIN" ] && return 0
  done
  return 1
}

if needs_build; then
  mkdir -p "$APP/Contents/MacOS"
  swiftc -target "$TARGET" -O -suppress-warnings -o "$BIN.new" "$REPO"/src/*.swift
  mv -f "$BIN.new" "$BIN"
  cp "$REPO/app/Info.plist" "$APP/Contents/Info.plist"
  # Ad-hoc is enough because nothing here was downloaded, so nothing is
  # quarantined. It does mean the Calendar grant is keyed to this build's
  # cdhash and a rebuild may ask again.
  codesign --force --sign - "$APP"
  echo "Built MeetingAlarm.app."
fi

"$BIN" install
echo "Check with: $REPO/bin/meeting-alarm status"
