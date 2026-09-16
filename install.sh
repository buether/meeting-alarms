#!/bin/bash
# Builds the signed launcher bundle, renders the LaunchAgent plists, and loads them.
# Safe to re-run; it only rebuilds the bundle when launcher sources changed.
set -euo pipefail

REPO="$(cd "$(dirname "$0")" && pwd)"
PYTHON="$(command -v "${PYTHON:-python3}" || true)"
LABEL=com.buether.meeting-alarm
APP="$REPO/build/MeetingAlarm.app"
BIN="$APP/Contents/MacOS/meeting-alarm-launcher"
AGENTS="$HOME/Library/LaunchAgents"
LOGS="$HOME/Library/Logs/meeting-alarm"
DOMAIN="gui/$(id -u)"

[ -f "$REPO/config.json" ] || cp "$REPO/config.example.json" "$REPO/config.json"
[ -n "$PYTHON" ] || { echo "python3 not found on PATH (set PYTHON=/path/to/python3)"; exit 1; }
for tool in cc swiftc; do
  command -v "$tool" >/dev/null || { echo "$tool is missing: xcode-select --install"; exit 1; }
done

CALENDAR="$APP/Contents/MacOS/meeting-alarm-calendar"
if [ ! -x "$BIN" ] || [ ! -x "$CALENDAR" ] || \
   [ "$REPO/launcher/launcher.c" -nt "$BIN" ] || \
   [ "$REPO/calendar/main.swift" -nt "$CALENDAR" ] || \
   [ "$REPO/launcher/Info.plist" -nt "$APP/Contents/Info.plist" ]; then
  mkdir -p "$APP/Contents/MacOS"
  cc -O2 -Wall -o "$BIN" "$REPO/launcher/launcher.c"
  swiftc -O -suppress-warnings -o "$CALENDAR.new" "$REPO/calendar/main.swift"
  mv -f "$CALENDAR.new" "$CALENDAR"
  cp "$REPO/launcher/Info.plist" "$APP/Contents/Info.plist"
  codesign --force --sign - "$APP"
  echo "Built launcher bundle. macOS will ask once for Calendar access for 'Meeting Alarm'."
fi

DIALOG="$REPO/build/meeting-alarm-dialog"
if [ ! -x "$DIALOG" ] || [ "$REPO/dialog/main.swift" -nt "$DIALOG" ]; then
  mkdir -p "$REPO/build"
  swiftc -O -suppress-warnings -o "$DIALOG.new" "$REPO/dialog/main.swift"
  mv -f "$DIALOG.new" "$DIALOG"
  echo "Built alarm window."
fi

mkdir -p "$AGENTS" "$LOGS"
for tmpl in "$REPO"/launchd/*.plist.tmpl; do
  name="$(basename "$tmpl" .tmpl)"
  sed -e "s|@REPO@|$REPO|g" -e "s|@HOME@|$HOME|g" -e "s|@PYTHON@|$PYTHON|g" "$tmpl" > "$AGENTS/$name"
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
