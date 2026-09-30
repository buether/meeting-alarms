# Homebrew packaging

Shipped through a personal tap, `buether/homebrew-tap`:
`brew install buether/tap/meeting-alarm && meeting-alarm install`. The formula
there is the source of truth; the draft below is a copy for reference.

## Settled

**A formula built from source, not a cask.** Homebrew quarantines cask
downloads, so an ad-hoc signed `MeetingAlarm.app` would be blocked by Gatekeeper
until it is notarized. Compiling on the user's machine produces binaries with no
quarantine attribute, so `codesign --sign -` is enough.

**No interpreter.** The Swift port removed the Python half of the install, so
`depends_on xcode: :clt` is now only there for `swiftc`.

**The agents clean up after themselves.** A formula has no uninstall hook —
`uninstall_preflight` and `uninstall_postflight` are Cask stanzas, and
`brew uninstall` touches no launchd state at all — so `brew uninstall` would
leave two agents firing every minute at a deleted Cellar path. Both agents
therefore run `run-agent.sh`, written into Application Support where it
outlives whatever removed the binary. It execs the binary when it is there and
otherwise unloads both agents, deletes both plists and deletes itself, keeping
config, history and logs. The exec keeps launchd's job process on the signed
bundle, which is what the Calendar grant is attached to. This covers a deleted
checkout too.

**The agents are ours, not `brew services`.** A formula gets one service block
and Homebrew's cron parser takes a single value per field, so the watchdog's
10:05 and 14:05 cannot be expressed. Running both a `service do` block and our
own agents would put two pollers on a 60-second interval and two windows on
screen for one meeting. So: no `service do`, and `meeting-alarm install` owns
both LaunchAgents.

## To do

Nothing blocking. Verified against a real `brew install` of 1.0.0: `swiftc`
builds under superenv, `codesign` works inside the build sandbox, `brew test`
and `brew audit --strict --online` pass, and the Cellar build read the calendar
without a new prompt.

## Learned the hard way

A poll that blocks forever wedges the job: launchd does not start the next one
while it runs. On 2026-09-19 a rebuild raised a Calendar prompt, the lid was
closed on it, and the poller stayed stuck for eleven days — past the laptop
being opened again — while the watchdog logged `stale` twice a day. Every poll
now has a deadline (150s, `$MEETING_ALARM_POLL_DEADLINE`) after which it records
a failure and `_exit`s, so the next poll starts and the failure notice can fire.

The poller was scheduled with StartInterval, and on the development Mac that
never fired once: launchd had the login session's domain in on-demand-only
mode (`on-demand count = 2` in `launchctl print gui/$UID`; log line "pending
spawn, domain in on-demand-only mode"), which pends every StartInterval spawn.
The Mac had been up 55 days and its hourly Google and Zoom updaters had run 17
times. Every poll ever logged was an install or a kickstart. StartCalendarInterval
jobs still fire in that mode, so the poller now runs every minute by calendar.
When checking something like this, zsh's `log` is a builtin: use /usr/bin/log.

The cdhash theory of the Calendar grant is not what was observed. Rebuilds,
the move to the Cellar and even fresh bundle identifiers mostly kept access
without a prompt, yet one rebuild did prompt. Treat a prompt as possible after
any rebuild, and do not promise either outcome in the README.

The `install` subcommand rewrites a Cellar path through `opt` before it goes in
a plist, so `brew upgrade` does not leave an agent pointing at a version
directory that no longer exists. It also injects `MEETING_ALARM_LABEL` into the
poller when the label is not the default, so a relabelled install's own `status`
and `test` look at the right job.

## Formula draft

```ruby
class MeetingAlarm < Formula
  desc "Loud alarm 15 seconds before a meeting starts"
  homepage "https://github.com/buether/meeting-alarms"
  url "https://github.com/buether/meeting-alarms/archive/refs/tags/v1.0.0.tar.gz"
  sha256 ""
  license "MIT"

  depends_on xcode: :clt
  depends_on macos: :sonoma

  def install
    app = libexec/"MeetingAlarm.app"
    (app/"Contents/MacOS").mkpath
    system "swiftc", "-target", "#{Hardware::CPU.arch}-apple-macos14.0",
           "-O", "-suppress-warnings",
           "-o", app/"Contents/MacOS/meeting-alarm", *Dir["src/*.swift"]
    (app/"Contents").install "app/Info.plist"
    system "codesign", "--force", "--sign", "-", app

    (bin/"meeting-alarm").write <<~BASH
      #!/bin/bash
      exec "#{opt_libexec}/MeetingAlarm.app/Contents/MacOS/meeting-alarm" "$@"
    BASH
  end

  def caveats
    <<~TEXT
      Load the background jobs with:
        meeting-alarm install

      They remove themselves within a minute of `brew uninstall`. Config,
      history and logs under ~/Library are left alone.
    TEXT
  end

  test do
    assert_match "watchdog", shell_output("#{bin}/meeting-alarm --help")
  end
end
```

Every path uses `opt_libexec`, which does not change when the Cellar version
does. The agents run the bundle executable directly, so macOS attributes the
Calendar request to the signed bundle.

## Also open

- **A Developer ID certificate.** Ad-hoc signing keys the Calendar grant to a
  cdhash that every rebuild changes. A Developer ID moves it to a Team ID that
  survives upgrades, and would also make a cask viable. $99/yr.
- **Sandboxing and `SMAppService`,** if this ever goes to the App Store. The App
  Store forbids writing `~/Library/LaunchAgents`, so `install.sh` and both
  plists would become a login item the app registers for itself. That also
  retires the cdhash problem, since App Store signing keys the grant to a Team
  ID.
