# Meeting Alarm

An alarm that goes off 15 seconds before a meeting starts and keeps ringing
until you click Dismiss or Join. For macOS.

A calendar notification ten minutes ahead arrives while you are in the middle
of something, and is gone by the time you surface.

- Wakes the display, raises the volume, speaks, and loops a sound.
- The alarm window sits above every Space and full-screen app.
- **Join** opens the Zoom, Teams, Meet or Webex link from the invitation.
- Reads Calendar.app, so every account your Mac already syncs is covered.
- Silent for all-day events and invitations you declined.
- Nothing to sign in to, no API keys, nothing leaves the Mac.

## Install

Needs macOS 14 or later and the Xcode command line tools, which supply the
`swiftc` the installer uses:

```
xcode-select --install
```

Then:

```
git clone https://github.com/buether/meeting-alarms.git
cd meeting-alarms
./install.sh
```

macOS asks once whether **Meeting Alarm** may read your calendar. Click Allow.
Then hear it:

```
bin/meeting-alarm test
```

That test goes through launchd and the signed bundle, the same path a real
alarm takes.

Keep the clone where it is. The launchd job runs the code from this directory,
so moving or deleting the clone stops the alarms.

### Make a Google calendar sync fast enough

Add the account under System Settings > Internet Accounts, Calendars only,
then set Calendar.app > Settings > Accounts > Refresh Calendars to **Every
minute**. Google does not push to Calendar.app, and at the default interval a
meeting added this morning can be missed.

## What an alarm does

Fifteen seconds before the start, your Mac wakes the display, raises the output
volume to 75 percent, says "Meeting starting", and loops a sound. A window
naming the meeting floats above whatever you are doing. **Join** opens the
meeting link. **Dismiss** stops the alarm. Both restore the volume and mute
state you had. Fifteen minutes after the start the alarm gives up, so a meeting
you are not there for does not ring all afternoon.

Every number there is a setting.

## Which meetings ring

A meeting rings when someone other than you is on it and you have accepted it
or not answered yet. All-day events, canceled events, events you declined or
marked tentative, and events only you are on stay silent.

Each occurrence rings once. Move a meeting and it rings again at its new time.
A meeting still in progress rings however late your Mac woke up; one that has
already ended does not. An event with a field it cannot read rings anyway,
because a missed meeting costs more than a spurious alarm.

`bin/meeting-alarm status` applies those rules to the next eight hours and
prints a verdict and a reason for every event.

## Commands

```
bin/meeting-alarm status            poller health, recent alarms, and a verdict per event for the next 8 hours
bin/meeting-alarm poll --dry-run    what this minute's poll would do, without ringing anything
bin/meeting-alarm test              ring a test alarm
bin/meeting-alarm calendars         calendar titles and account names EventKit can see
bin/meeting-alarm install           write and load the two LaunchAgents for wherever this binary lives
bin/meeting-alarm uninstall         unload and remove them; logs and history stay
./install.sh                        rebuild, then install; run after changing the code or poll_seconds
./uninstall.sh                      uninstall, then delete build/
```

`poll.log`, `alarm.log` and `launchd.log` are in `~/Library/Logs/meeting-alarm/`.

## Settings

`install.sh` writes a config file on first run at
`~/Library/Application Support/meeting-alarm/config.json`, outside the install
directory so an upgrade cannot delete it. `config.example.json` shows the same
keys. Leave a key out and the default applies. Edits take effect at the next
poll, within a minute; `poll_seconds` is the exception and needs
`./install.sh`.

Three places are checked, first hit wins: `$MEETING_ALARM_CONFIG`, then that
Application Support path, then a `config.json` in a checkout — which is handy
while working on the code and is not committed.

| Key | Default | What it does |
| --- | --- | --- |
| `message` | `Meeting starting` | Headline in the window, and the spoken words. |
| `sound` | Silk | Sound file to loop. Full path; see below. |
| `volume` | `75` | Output volume while ringing, 0 to 100. Your level and mute state come back afterwards. |
| `speak` | `true` | Say `message` out loud before the sound starts. |
| `break_mute` | `true` | Ring through a muted Mac, then put the mute back. `false` respects the mute and leaves the output alone, so the alarm is silent but the window still appears. |
| `lead_seconds` | `15` | Seconds before the start that it rings. |
| `max_alarm_seconds` | `900` | Seconds after the start to give up. `0` rings until dismissed. |
| `include_calendars` | `[]` | Calendar titles to watch. Empty watches all of them. |
| `fallback_sound` | Sosumi | Used when `sound` is not on disk. With neither, the alarm still speaks and shows the window. |
| `expected_source` | `null` | Account name that must still be present, so a signed-out account is reported rather than looking like an empty calendar. |
| `poll_seconds` | `60` | Seconds between calendar checks. |

To fill in `include_calendars` or `expected_source`, list what EventKit sees:

```
bin/meeting-alarm calendars
```

Three keys govern how the tool reports its own failures and are absent from
`config.example.json`: `failure_notice_after_seconds` (1800) is how long polls
must fail before it says so, `failure_notice_every_seconds` (14400) the
shortest gap between those warnings, and `fired_retention_seconds` (172800)
how long a meeting is remembered as already rung.

## Sounds

The default is Silk, one of Apple's ringtones. They live here:

```
/System/Library/PrivateFrameworks/ToneLibrary.framework/Versions/A/Resources/Ringtones/
```

Gentler ones in that directory are Ripples, Harp, Chimes, Waves, Slow Rise and
By The Seaside. Alarm is the loud one. Anything in `/System/Library/Sounds/`
works too. To hear one before you keep it, put its path in `config.json` and
ring a ten-second alarm:

```
bin/meeting-alarm alarm --title Test --start $(date +%s) --max-seconds 10
```

## When something goes wrong

The tool reports its own failures. After polls have been failing for half an
hour a dialog says so, and a watchdog checks at 10:05 and 14:05 and complains
if nothing has succeeded in three hours. To check for yourself:

```
bin/meeting-alarm status
```

A healthy answer has a `last successful poll` under a minute old and names a
sound file rather than `MISSING`.

- **`FAILING` with "Calendar access denied".** Turn Meeting Alarm on under
  System Settings > Privacy & Security > Calendars. To get the prompt back,
  run `tccutil reset Calendar com.buether.meeting-alarm` and `./install.sh`.
- **`launchd: NOT LOADED`.** `./install.sh` did not finish. Run it again and
  read its output.
- **No events listed, though you have meetings.** Calendar.app has not synced
  them. Set its refresh interval, as under Install.
- **A window and speech, but no repeating sound.** Neither `sound` nor
  `fallback_sound` is on disk, and `alarm.log` says `no sound file found`.

## Limitations

- A meeting only you are on never rings, even with a link on it.
- Calendar.app cannot tell whether you already joined, so a meeting in
  progress may ring while you are already in it.
- The sound follows your selected output device and raises that device's
  volume. Headphones off your head take the alarm with them.

## How it works

launchd runs `meeting-alarm poll` every 60 seconds. The poll asks EventKit for
events between eight hours ago and a couple of minutes ahead. Reading
Calendar.app is what covers every account your Mac syncs and leaves no Google
API client to maintain. A meeting that is due gets a detached `meeting-alarm
alarm` process, spawned up to a minute early and waiting out the difference, so
the alarm outlives the poll that started it.

Everything is one Swift binary inside `build/MeetingAlarm.app`, a signed bundle
built on your machine from `src/`, because macOS only offers the Calendar
permission prompt to a bundled app that declares why it wants access. The
signature covers the whole bundle, so the only thing that reads your calendar is
code in this repository, and changing that code makes macOS ask you again.

Two meetings a minute apart put two alarm windows on screen. Only the one
holding `alarm.lock` raises the volume and loops the sound, so they do not
fight over the output device.

Both agents run `run-agent.sh`, written into
`~/Library/Application Support/meeting-alarm/` at install time. It hands off to
the binary with `exec`, so launchd's job process ends up being the signed
bundle. If the binary is ever gone — an uninstall, a deleted checkout — the
script instead unloads both agents, deletes both plists and deletes itself,
rather than leaving launchd firing every minute at a path that no longer
exists. Your config, alarm history and logs are left alone.

Run `./run-tests.sh` to build and run the unit tests. They cover the selection
logic, so they need no calendar, no permissions and no window server.

## License

MIT. See [LICENSE](LICENSE).

Built by [John Buether](https://github.com/buether).
