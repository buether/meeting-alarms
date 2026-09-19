# Homebrew packaging

Ship meeting-alarm through a personal tap: `brew tap buether/tap && brew install
meeting-alarm`.

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

- [ ] Verify the build under Homebrew, not just in a checkout: `swiftc` through
      superenv's filtered PATH, and `codesign` inside the build sandbox.
- [ ] Verify the Calendar grant survives the bundle moving to a Cellar path.
      Two local rebuilds kept it, which is weak evidence — the cdhash changed
      both times and TCC did not re-prompt, so the mechanism is not yet
      understood well enough to promise either outcome in the README.
- [ ] Tag v1.0.0 and take the sha256 of the GitHub tarball.
- [ ] Create the tap repository, `homebrew-tap`, holding the formula at
      `Formula/meeting-alarm.rb`.

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
