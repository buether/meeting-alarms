#!/bin/bash
# Unloads and removes the LaunchAgents and the built bundle. Keeps state and logs.
set -uo pipefail

REPO="$(cd "$(dirname "$0")" && pwd)"
BIN="$REPO/build/MeetingAlarm.app/Contents/MacOS/meeting-alarm"

if [ -x "$BIN" ]; then
  "$BIN" uninstall
else
  # The build is already gone, so unload by label instead.
  LABEL="${MEETING_ALARM_LABEL:-com.buether.meeting-alarm}"
  for label in "$LABEL" "$LABEL.watchdog"; do
    launchctl bootout "gui/$(id -u)/$label" 2>/dev/null
    rm -f "$HOME/Library/LaunchAgents/$label.plist"
  done
  rm -f "$HOME/Library/Application Support/meeting-alarm/run-agent.sh"
  echo "Unloaded and removed both LaunchAgents."
fi

rm -rf "$REPO/build"
echo "Removed build/."
