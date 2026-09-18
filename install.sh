#!/bin/bash
# Builds the signed app bundle, renders the LaunchAgent plists, and loads them.
# Safe to re-run; it only rebuilds the bundle when the sources changed.
set -euo pipefail

REPO="$(cd "$(dirname "$0")" && pwd)"
LABEL="${MEETING_ALARM_LABEL:-com.buether.meeting-alarm}"
APP="$REPO/build/MeetingAlarm.app"
BIN="$APP/Contents/MacOS/meeting-alarm"
AGENTS="$HOME/Library/LaunchAgents"
LOGS="$HOME/Library/Logs/meeting-alarm"
DOMAIN="gui/$(id -u)"
TARGET="$(uname -m)-apple-macos14.0"

[ -f "$REPO/config.json" ] || cp "$REPO/config.example.json" "$REPO/config.json"
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
  # cdhash and a rebuild asks again.
  codesign --force --sign - "$APP"
  echo "Built MeetingAlarm.app. macOS will ask once for Calendar access for 'Meeting Alarm'."
fi

mkdir -p "$AGENTS" "$LOGS"
for tmpl in "$REPO"/launchd/*.plist.tmpl; do
  name="$(basename "$tmpl" .tmpl)"
  sed -e "s|@REPO@|$REPO|g" -e "s|@HOME@|$HOME|g" "$tmpl" > "$AGENTS/$name"
  plutil -lint -s "$AGENTS/$name"
done

for label in "$LABEL" "$LABEL.watchdog"; do
  launchctl bootout "$DOMAIN/$label" 2>/dev/null || true
  launchctl enable "$DOMAIN/$label" 2>/dev/null || true
  launchctl bootstrap "$DOMAIN" "$AGENTS/$label.plist"
done
launchctl kickstart -k "$DOMAIN/$LABEL"

echo "Installed. If a Calendar access prompt for 'Meeting Alarm' appears, click Allow."
echo "Check with: $REPO/bin/meeting-alarm status"
