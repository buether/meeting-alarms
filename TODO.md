# Homebrew packaging

Ship meeting-alarm through a personal tap: `brew tap buether/tap && brew install
meeting-alarm`.

## Settled

**A formula built from source, not a cask.** Homebrew quarantines cask
downloads, so an ad-hoc signed `MeetingAlarm.app` would be blocked by Gatekeeper
until it is notarized. Compiling on the user's machine produces binaries with no
quarantine attribute, so `codesign --sign -` is enough.

**No interpreter.** The Swift port removed the Python half of the install, so
`depends_on xcode: :clt` is now only there for `swiftc`. Nothing in the formula
depends on a language runtime that Apple ships as a Command Line Tools
component rather than a platform API.

**Ad-hoc signing, for now.** Every upgrade rebuilds the binary, changes its
cdhash, and costs the user the Calendar grant. A Developer ID certificate would
replace the cdhash requirement with a Team ID one that survives upgrades; until
then the `tccutil reset` in the README is the fix.

## To do

- [ ] Add a `meeting-alarm install` subcommand that renders and loads both
      agents, taking over the launchd half of install.sh; install.sh keeps the
      build and calls it. A formula gets one service block, and Homebrew's cron
      parser takes a single value per field, so the watchdog's 10:05 and 14:05
      cannot be a second brew service.
- [ ] Exercise `status`, `test` and `alarm` from a Cellar install. The unit
      tests cover selection logic only; nothing has run the EventKit, CoreAudio
      or AppKit paths against `opt_libexec` paths.
- [ ] Tag v1.0.0 and take the sha256 of the GitHub tarball.
- [ ] Create the tap repository, `homebrew-tap`, holding the formula at
      `Formula/meeting-alarm.rb`.

## Closed by the Swift port

- Config no longer sits next to the binary. `Paths.configPath` resolves
  `$MEETING_ALARM_CONFIG`, then `~/Library/Application Support/meeting-alarm/config.json`,
  then the repository copy, then the built-in defaults.
- The launchd label is no longer hardcoded. `$MEETING_ALARM_LABEL` overrides it,
  so `test` and `status` can be pointed at `homebrew.mxcl.meeting-alarm`.
- `launcher.c` is gone. It existed to keep launchd's job process on the signed
  bundle while the real work happened in a Python child; the bundle executable
  now does the work itself.
- An event with a nil `startDate` or `endDate` is no longer dropped before the
  fail-safe sees it.
- The empty-calendar-list guard has a comment: an empty array would mean "every
  calendar" to `predicateForEvents`, the opposite of what `include_calendars`
  matching nothing should produce.

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
    pkgshare.install "config.example.json"

    (bin/"meeting-alarm").write <<~BASH
      #!/bin/bash
      exec "#{opt_libexec}/MeetingAlarm.app/Contents/MacOS/meeting-alarm" "$@"
    BASH
  end

  service do
    run [opt_libexec/"MeetingAlarm.app/Contents/MacOS/meeting-alarm", "poll"]
    run_type :interval
    interval 60
    log_path var/"log/meeting-alarm.log"
    error_log_path var/"log/meeting-alarm.log"
    environment_variables MEETING_ALARM_LABEL: "homebrew.mxcl.meeting-alarm"
  end

  test do
    assert_match "watchdog", shell_output("#{bin}/meeting-alarm --help")
  end
end
```

Every path uses `opt_libexec`, which does not change when the Cellar version
does. The service runs the bundle executable directly, so macOS attributes the
Calendar request to the signed bundle.

## Also open

- Sandboxing and `SMAppService`, if this ever goes to the App Store. The App
  Store forbids writing `~/Library/LaunchAgents`, so `install.sh` and both
  plists would become a login item the app registers for itself. That also
  retires the cdhash problem, since App Store signing keys the Calendar grant
  to a Team ID.
