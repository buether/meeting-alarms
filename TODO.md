# Homebrew packaging

Ship meeting-alarm through a personal tap: `brew tap buether/tap && brew install
meeting-alarm`.

## Settled

**A formula built from source, not a cask.** Homebrew quarantines cask
downloads, so an ad-hoc signed `MeetingAlarm.app` would be blocked by Gatekeeper
until it is notarized. Compiling on the user's machine produces binaries with no
quarantine attribute, so `codesign --sign -` is enough.

**`/usr/bin/python3`, not a Homebrew Python.** The Command Line Tools ship
Python 3.9.6 as of macOS 26.6. The test suite passes on it and both Python files
parse on it, so the formula needs no Python dependency: `depends_on xcode:
:clt` already covers `cc`, `swiftc` and the interpreter. The cost is no 3.10+
syntax, ever. Run the suite under both interpreters before a release.

**Ad-hoc signing, for now.** Every upgrade rebuilds the launcher, changes its
cdhash, and costs the user the Calendar grant. A Developer ID certificate would
replace the cdhash requirement with a Team ID one that survives upgrades; until
then the `tccutil reset` in the README is the fix.

## To do

- [ ] Resolve the config path outside the install directory. `CONFIG_PATH`
      (meeting_alarm.py:25) sits next to the script, which under Homebrew is
      `libexec` in the Cellar and is deleted on upgrade. Order:
      `$MEETING_ALARM_CONFIG`, `~/Library/Application Support/meeting-alarm/config.json`,
      the repository copy, `DEFAULTS`.
- [ ] Stop hardcoding the launchd label. `LABEL` (meeting_alarm.py:26) is what
      `test` kickstarts and `status` prints, and `brew services` labels its job
      `homebrew.mxcl.meeting-alarm`, so both subcommands would report NOT LOADED
      against a healthy service. Read an environment variable, keep the current
      value as the default. The bundle identifier in launcher/Info.plist is a
      separate thing and does not move.
- [ ] Add a `meeting-alarm install` subcommand that renders and loads both
      agents, taking over the launchd half of install.sh; install.sh keeps the
      build and calls it. A formula gets one service block, and Homebrew's cron
      parser takes a single value per field, so the watchdog's 10:05 and 14:05
      cannot be a second brew service.
- [ ] Exercise `status`, `test` and `alarm` under `PYTHON=/usr/bin/python3`. The
      test suite covers selection logic only; nothing runs the subprocess,
      osascript or fcntl paths on 3.9.
- [ ] Tag v1.0.0 and take the sha256 of the GitHub tarball.
- [ ] Create the tap repository, `homebrew-tap`, holding the formula at
      `Formula/meeting-alarm.rb`.

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
    macos_dir = libexec/"MeetingAlarm.app/Contents/MacOS"
    macos_dir.mkpath
    system ENV.cc, "-O2", "-Wall", "-o", macos_dir/"meeting-alarm-launcher", "launcher/launcher.c"
    system "swiftc", "-O", "-suppress-warnings", "-o", macos_dir/"meeting-alarm-calendar",
           "calendar/main.swift"
    (libexec/"MeetingAlarm.app/Contents").install "launcher/Info.plist"
    system "codesign", "--force", "--sign", "-", libexec/"MeetingAlarm.app"

    system "swiftc", "-O", "-suppress-warnings", "-o", libexec/"meeting-alarm-dialog",
           "dialog/main.swift"
    libexec.install "meeting_alarm.py"
    pkgshare.install "config.example.json"

    (bin/"meeting-alarm").write <<~BASH
      #!/bin/bash
      exec "${PYTHON:-/usr/bin/python3}" "#{opt_libexec}/meeting_alarm.py" "$@"
    BASH
  end

  service do
    run [opt_libexec/"MeetingAlarm.app/Contents/MacOS/meeting-alarm-launcher",
         "/usr/bin/python3", opt_libexec/"meeting_alarm.py", "poll"]
    run_type :interval
    interval 60
    log_path var/"log/meeting-alarm.log"
    error_log_path var/"log/meeting-alarm.log"
    environment_variables PATH: std_service_path_env
  end

  test do
    assert_match "watchdog", shell_output("#{bin}/meeting-alarm --help")
  end
end
```

The service runs the launcher bundle with the interpreter as its argument, so
macOS still attributes the Calendar request to the signed bundle. Every path
uses `opt_libexec`, which does not change when the Cellar version does.

## Also open

- calendar/main.swift:155 drops an event whose `startDate` or `endDate` is nil.
  The Python side alarms on fields it cannot read, and `FailSafeTests` pins
  that, so the guard removes the case before it reaches the fail-safe.
- calendar/main.swift:146 returns early when the calendar list is empty. If the
  reason is that an empty array makes `predicateForEvents` match every calendar,
  that deserves a comment. Confirm before writing one.
- Porting meeting_alarm.py to Swift ends the interpreter question and leaves one
  signed bundle. Apple ships python3 as a Command Line Tools component, not a
  platform API.
