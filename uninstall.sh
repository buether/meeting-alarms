#!/bin/bash
# Unloads and removes the LaunchAgents and the built bundle. Keeps state and logs.
set -uo pipefail

REPO="$(cd "$(dirname "$0")" && pwd)"
LABEL=com.buether.meeting-alarm
AGENTS="$HOME/Library/LaunchAgents"
DOMAIN="gui/$(id -u)"

for label in "$LABEL" "$LABEL.watchdog"; do
  launchctl bootout "$DOMAIN/$label" 2>/dev/null || true
  rm -f "$AGENTS/$label.plist"
done
rm -rf "$REPO/build"
echo "Removed LaunchAgents and build/."
echo "Left in place: ~/Library/Application Support/meeting-alarm and ~/Library/Logs/meeting-alarm"
echo "To forget the Calendar grant: tccutil reset Calendar $LABEL"
