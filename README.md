# Meeting Alarm

An alarm that goes off 15 seconds before a meeting starts and keeps ringing
until you click Dismiss or Join. For macOS.

A calendar notification ten minutes ahead arrives while you are in the middle
of something, and is gone by the time you surface.

- Wakes the display, raises the volume, speaks, and loops a sound.
- The alarm window sits above every Space and full-screen app.
- **Join** opens the Zoom, Teams, Meet or Webex link from the invitation.
  Your Mac's default app handles links unless you choose an override in
  **Meeting Link Settings**, available from the alarm's corner gear.
- Reads Calendar.app, so every account your Mac already syncs is covered.
- Silent for all-day events and invitations you declined.
- Nothing to sign in to, no API keys, nothing leaves the Mac.

## Install

```
brew install buether/tap/meeting-alarm && meeting-alarm install
```

Needs macOS 14 or later and the Xcode command line tools, which supply the
`swiftc` the formula builds with. If brew says they are missing, run
`xcode-select --install` first.

macOS asks once whether **Meeting Alarm** may read your calendar. Click Allow.
Then hear it:

```
meeting-alarm test
```

That test goes through launchd and the signed bundle, the same path a real
alarm takes.

To remove it, `brew uninstall meeting-alarm`. The background jobs notice within
a minute and remove themselves; your config, alarm history and logs under
`~/Library` stay.

### From a checkout

```
git clone https://github.com/buether/meeting-alarms.git
cd meeting-alarms
./install.sh
```

Commands are then `bin/meeting-alarm …` instead of `meeting-alarm …`. The jobs
run the code from the clone, so moving or deleting it stops the alarms — and
the jobs then remove themselves, as after an uninstall. `./uninstall.sh` takes
them down deliberately and deletes `build/`.

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

## Check your setup

Run `meeting-alarm status` after installing and after any change to the
config. Nothing pops up to tell you a setting is wrong; this listing is the
check.

```
POLLER     running - last successful poll 20s ago
SOUND      Silk.m4r
CONFIG     ~/Library/Application Support/meeting-alarm/config.json

CALENDARS  watching 1 of 2  (include_calendars: ["Work"])
  watched      Google   Work
  not watched  Google   Family

NEXT 8 HOURS  3 will ring, 5 will not
  all day   silent Offsite                        Work      all-day
  13:06     rings  Planning                       Work      my status accepted, in progress
  13:36     rings  Standup                        Work      my status accepted
  14:46     rings  Design review                  Work      my status pending
  15:16     silent Focus time                     Work      no other attendees
  15:46     silent 1:1 with Sam                   Work      my status declined
  16:36     silent Soccer pickup                  Family    calendar not watched
  18:16     silent Dinner at Mom's                Family    calendar not watched

No problems found.
```

Every event in every calendar is listed, including the ones that will not
ring and why, so you can confirm both halves: what you expect to ring does,
and what you expect to stay quiet does. Anything wrong is in capitals —
`STALLED`, `FAILING`, `NOT LOADED`, `MISSING` for the sound, and `NO MATCH`
for an `include_calendars` name that matches no calendar, with a suggestion
when only the case is off. The last line counts the problems.

## Commands

```
meeting-alarm status                check your setup: poller health, watched calendars, a verdict per event
meeting-alarm poll --dry-run        what this minute's poll would do, without ringing anything
meeting-alarm test                  ring a test alarm
meeting-alarm calendars             calendar titles and account names EventKit can see
meeting-alarm settings              choose apps for meeting links
meeting-alarm install               write and load the three LaunchAgents for wherever this binary lives
meeting-alarm uninstall             unload and remove them; logs and history stay
meeting-alarm help                  most of this README, in the terminal
./install.sh                        in a checkout: rebuild, then install
./uninstall.sh                      in a checkout: uninstall, then delete build/
```

`poll.log`, `alarm.log` and `launchd.log` are in `~/Library/Logs/meeting-alarm/`.

## Menu bar

Installing starts a small bell in the menu bar and brings it back at login.
A plain bell means the poller is loaded and calendar checks are recent. A badged
bell means checks have failed, stalled, or the poller is not loaded. Hover for
the current status, or click it to refresh status and open Settings. It checks
the same health information as `meeting-alarm status`, updating every 30 seconds
and when the Mac wakes. The icon does not read calendars or play an alarm.

Existing installs need `meeting-alarm install` once to add the menu bar job.
`meeting-alarm uninstall` removes it with the other background jobs.

## Settings

Click the gear in the alarm's bottom-right corner, or run `meeting-alarm settings`,
to choose an app for Google Meet, Zoom, Teams, Webex or other links. Each starts
with **macOS default**. **Choose app…** lets you pick a browser, meeting app or
saved web app from your Mac, including apps in `~/Applications/Chrome Apps.localized`.
Choices save immediately and apply to the next Join click, including the current
alarm. If a chosen app is removed or fails to launch, the original URL goes to
your Mac's default handler. Selecting **macOS default** removes that override.

For a Chrome web app, **Choose profile…** pins Join to a Chrome profile. Switch
to the desired profile in Chrome, open `chrome://version`, then copy **Profile
Path** into the settings dialog. The web app must be installed in that profile;
sign in to your meeting account there. A Chrome profile can contain several
Google accounts, so check the account shown in Meet before joining.

**Chrome chooses profile** uses the profile recorded in the app bundle, or lets
Chrome choose when the app is shared. Changing the chosen app clears its pinned
profile. If a pinned profile folder is unavailable, the original URL goes to the
Mac's default handler. Meeting Alarm does not read Chrome's private profile
preferences.

`meeting-alarm install` writes a config file on first run at
`~/Library/Application Support/meeting-alarm/config.json`, outside the install
directory so an upgrade cannot delete it. `config.example.json` shows the same
keys. Leave a key out and the default applies. Edits take effect at the next
poll, within a minute; `poll_seconds` is the exception and needs
`meeting-alarm install` again.

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
| `include_calendars` | `[]` | Calendar titles to watch, e.g. `["Work"]`. Empty watches all of them. Exact and case-sensitive; `status` shows which calendars are watched and flags a name that matches none. |
| `fallback_sound` | Sosumi | Used when `sound` is not on disk. With neither, the alarm still speaks and shows the window. |
| `expected_source` | `null` | Account name that must still be present, so a signed-out account is reported rather than looking like an empty calendar. |
| `meeting_apps` | `{}` | Optional app paths keyed by `google_meet`, `zoom`, `teams`, `webex` or `other`. For example, `{"google_meet": "/Users/you/Applications/Google Meet.app"}`. The settings window writes these and preserves other config keys. |
| `meeting_app_profiles` | `{}` | Optional full Chrome Profile Paths keyed by the same service names as `meeting_apps`. Used only for explicitly selected Chrome web apps. Find a path in `chrome://version`, for example `/Users/you/Library/Application Support/Google/Chrome/Profile 2`. |
| `poll_seconds` | `60` | Seconds between calendar checks. Rounds to whole minutes. |

To fill in `include_calendars` or `expected_source`, list what EventKit sees:

```
meeting-alarm calendars
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
meeting-alarm alarm --title Test --start $(date +%s) --max-seconds 10
```

## When something goes wrong

Run `meeting-alarm status`. Anything wrong is in capitals. (After half an
hour of failed polls a dialog also says so, and a watchdog complains at 10:05
and 14:05 if nothing has succeeded in three hours, but don't rely on noticing
those.)

- **`STALLED`.** No poll has succeeded for a while. If the Mac has just woken
  up, check again in a minute; otherwise run `meeting-alarm install`.
- **`NO MATCH` or `NOTHING WILL RING`.** Fix the `include_calendars` name it
  quotes. Names are exact and case-sensitive.

- **`FAILING` with "Calendar access denied".** Turn Meeting Alarm on under
  System Settings > Privacy & Security > Calendars. To get the prompt back,
  run `tccutil reset Calendar com.buether.meeting-alarm` and `meeting-alarm install`.
- **`NOT LOADED`.** `meeting-alarm install` did not finish. Run it again and
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

launchd runs `meeting-alarm poll` at the top of every minute. The poll asks EventKit for
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

All three agents run `run-agent.sh`, written into
`~/Library/Application Support/meeting-alarm/` at install time. It hands off to
the binary with `exec`, so launchd's job process ends up being the signed
bundle. If the binary is ever gone — an uninstall, a deleted checkout — the
script instead unloads all three agents, deletes their plists and deletes itself,
rather than leaving launchd firing every minute at a path that no longer
exists. Your config, alarm history and logs are left alone.

Run `./run-tests.sh` to build and run the unit tests. They cover the selection
logic, so they need no calendar, no permissions and no window server.

## License

MIT. See [LICENSE](LICENSE).

Built by [John Buether](https://github.com/buether).
