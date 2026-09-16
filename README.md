# meeting-alarm

A loud alarm 15 seconds before a meeting starts, on macOS, that keeps
sounding until you click Dismiss. It exists because Google Calendar's
10-minute notification is easy to ignore when you are deep in something.

## How it works

launchd runs `meeting_alarm.py poll` every 60 seconds. The poll asks
`meeting-alarm-calendar`, a small EventKit client built from `calendar/main.swift`,
for the events in the window it cares about, so any account in Calendar.app works
and there is no Google OAuth client to maintain. An event alarms when
it is not all-day or canceled, has at least one other attendee, and your
response is anything except declined or tentative (unanswered invitations
alarm). Each occurrence alarms once, keyed by event id and start time. A move
changes the key, so the alarm follows the meeting to its new time. One that had
already alarmed before the move alarms again.

Past that the poll fails towards alarming. A meeting that has ended is the only
reason to stay silent about an eligible event: one still running alarms however
late the Mac woke up, and an event with a missing or unreadable field alarms
rather than being skipped.

The alarm is a detached process. The poll may spawn it up to a minute
early, so it first waits until exactly `lead_seconds` before the start. Then
it wakes the display, raises the output volume, speaks `message`, loops the
sound, and shows a native window that floats above every Space and
full-screen app with the message, the meeting name, and Join and Dismiss
buttons. Join opens the meeting link. Either button stops the sound
and restores the volume. A cap of `max_alarm_seconds` after the meeting
start stops an alarm nobody is around to hear.

The launchd job runs through a tiny signed app bundle, `build/MeetingAlarm.app`,
because macOS only shows the Calendar permission prompt to a bundled app
with a usage description. `meeting-alarm-calendar` lives inside that bundle and
is covered by the same signature, so the only code that reads your calendar is
code this repository builds. Changing `launcher.c` or `calendar/main.swift`
changes the bundle's signature and macOS asks for Calendar access again.

## Setup

1. System Settings > Internet Accounts > add the Google account, Calendars
   only.
2. Calendar.app > Settings > Accounts > Refresh Calendars: **Every minute**.
   Google CalDAV does not push to Calendar.app.
3. `./install.sh`, then click **Allow** on the "Meeting Alarm" calendar prompt.
4. `bin/meeting-alarm status` should show a recent successful poll.
5. Optional: set `expected_source` in `config.json` to the account's source
   title, so a signed-out account is reported instead of looking like an empty
   calendar. `build/MeetingAlarm.app/Contents/MacOS/meeting-alarm-calendar
   calendars` lists the titles.

## Commands

```
bin/meeting-alarm status                 poller health, sound file, recent alarms, next 8 hours with alarm/skip reasons
bin/meeting-alarm poll --dry-run         what this minute's poll would do, without alarming
bin/meeting-alarm poll --dry-run --now 2026-09-16T09:58:30
bin/meeting-alarm test                   ring a test alarm through the real launchd path
bin/meeting-alarm alarm --title Test --start $(date +%s) --max-seconds 10 --volume 30
./install.sh                             re-render plists and reload after config or code changes
./uninstall.sh
```

Logs: `~/Library/Logs/meeting-alarm/{poll,alarm,launchd}.log`.
State: `~/Library/Application Support/meeting-alarm/state.json`.

## Config

`install.sh` copies `config.example.json` to `config.json` on first run.
`config.json` is yours and is not committed. Any key below may appear in it;
anything it leaves out falls back to the default.

| Key | Default | What it does |
| --- | --- | --- |
| `lead_seconds` | `15` | Seconds before the start that the alarm sounds. |
| `poll_seconds` | `60` | How often launchd runs the poll. Must match `StartInterval` in the plist. |
| `max_alarm_seconds` | `900` | Give up this long after the meeting start. `0` rings until dismissed. |
| `message` | `Meeting starting` | Headline in the window, and the spoken text. |
| `volume` | `75` | Output volume while ringing, 0 to 100. The previous level and mute state are restored afterwards. |
| `speak` | `true` | Speak `message` through `say` before the sound starts looping. |
| `sound` | `Silk.m4r` | Sound file to loop. Full path; see below. |
| `fallback_sound` | `Sosumi.aiff` | Used when `sound` is not on disk. With neither on disk the alarm still speaks and shows the window, but nothing loops; `alarm.log` records `no sound file found`. |
| `include_calendars` | `[]` | Calendar titles to watch. Empty means all of them. |
| `expected_source` | `null` | Account source title that must still be present, so a signed-out account is reported instead of looking like an empty calendar. |
| `failure_notice_after_seconds` | `1800` | Show a dialog once polls have been failing for this long. |
| `failure_notice_every_seconds` | `14400` | Shortest gap between those dialogs. |
| `fired_retention_seconds` | `172800` | How long a fired occurrence is remembered, so it cannot alarm twice. |

The last three are not in `config.example.json`; add them only to change them.

Sounds: `sound` is Silk from Apple's tone library. Gentler neighbours in
`/System/Library/PrivateFrameworks/ToneLibrary.framework/Versions/A/Resources/Ringtones/`
are Ripples, Harp, Chimes, Waves, Slow Rise, and By The Seaside; the original
loud one is Alarm. Short system sounds in `/System/Library/Sounds/` also work.

## How to verify installation

Both agents are loaded:

```
launchctl list | grep meeting-alarm
```

Expect two lines, `com.buether.meeting-alarm` and the `.watchdog` one. Neither
means `./install.sh` did not finish; run it again and read its output.

The poller is succeeding:

```
bin/meeting-alarm status
```

`last successful poll` should be under a minute old, and `sound` should name a
file rather than `MISSING`. A sound reported as a fallback means the configured
one is not on disk. `FAILING` with "Calendar access denied" means the grant is
missing: enable Meeting Alarm under System Settings, Privacy & Security,
Calendars. To replay the prompt, run `tccutil reset Calendar
com.buether.meeting-alarm` and `./install.sh` again. If no prompt ever
appeared, this says whether macOS considered one:

```
log show --last 10m --predicate 'process == "tccd"' | grep -i meeting
```

The right events are selected:

```
bin/meeting-alarm poll --dry-run
```

One line per event in the window, each with FIRE or skip and the reason. An
empty list when you know you have meetings means Calendar.app has not synced;
Setup covers its refresh interval.

The alarm itself rings:

```
bin/meeting-alarm test
```

This runs through launchd and the signed bundle, so it exercises the path a
real alarm takes rather than a shortcut. Within a few seconds the display
wakes, the message is spoken, and the sound loops until you click Dismiss. A
spoken message and a window with no repeating sound means neither `sound` nor
`fallback_sound` is on disk.

Later failures report themselves. The poller shows a dialog once polls have
been failing for 30 minutes, and at most every 4 hours after that. A watchdog
agent checks at 10:05 and 14:05 and shows a dialog if no poll has succeeded in
3 hours.

## Limitations

- Events where you are the only attendee do not alarm, even with a meeting link.
- Calendar.app cannot tell whether you joined, so an alarm for a meeting
  already in progress may be for one you are already in.
- The alarm plays through whichever output device is selected, and raises that
  device's volume. Headphones left off your head take the sound with them.

## License

MIT. See [LICENSE](LICENSE).
