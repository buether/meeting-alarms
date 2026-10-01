import Foundation

/// `meeting-alarm help`: the README, cut down for a terminal. Setting defaults
/// come from `Config()` rather than being typed out, so they cannot drift from
/// what the binary does.
func helpText() -> String {
    let d = Config()
    let soundName = URL(fileURLWithPath: d.sound).deletingPathExtension().lastPathComponent
    let fallbackName = URL(fileURLWithPath: d.fallbackSound).deletingPathExtension().lastPathComponent
    let configPath = Paths.stateDir.appendingPathComponent("config.json").path
        .replacingOccurrences(of: FileManager.default.homeDirectoryForCurrentUser.path, with: "~")

    return """
    meeting-alarm — rings \(Int(d.leadSeconds)) seconds before a meeting starts and keeps
    ringing until you click Dismiss or Join.

    WHAT AN ALARM DOES
      Wakes the display, raises the volume to \(d.volume)%, says "\(d.message)", and
      loops a sound. A window naming the meeting floats above every Space and
      full-screen app. Join opens the Zoom, Teams, Meet or Webex link; Dismiss
      stops it. Both put your volume and mute back. It gives up
      \(Int(d.maxAlarmSeconds / 60)) minutes after the start.
      Google Meet links use a saved Chrome or Safari Meet app (Chrome first).
      Without a saved app, or if launching it fails, they use the default browser.

    WHICH MEETINGS RING
      Rings:   someone other than you is on it, and you accepted or have not
               answered.
      Silent:  all-day, canceled, declined, tentative, only-you events, and
               birthday and subscribed calendars.
      Each occurrence rings once; a moved meeting rings at its new time. A
      meeting still in progress rings however late the Mac woke; one that has
      ended does not. An event it cannot read rings anyway.

    CHECK YOUR SETUP
      Run `meeting-alarm status` after installing and after any config change.
      Nothing pops up to warn you; this listing is the check. It shows:
        POLLER      "running" and a recent poll, or what is wrong in CAPITALS
        CALENDARS   every calendar: watched, not watched, or never rings,
                    plus NO MATCH for an include_calendars name that is wrong
        NEXT 8 HOURS  every event in every calendar, "rings" or "silent",
                    and why - so confirm what you expect to ring does, and
                    what you expect to stay quiet does
      It ends with "No problems found." or a count of problems above.

    COMMANDS
      status              the check above
      test                ring a test alarm through the real path
      calendars           calendar titles and account names, for the settings
      poll --dry-run      what this minute's poll would do, ringing nothing
      install             write and load the two background jobs
      uninstall           remove them; config, history and logs stay
      help                this

      alarm --title T --start EPOCH [--url U] [--max-seconds N] [--volume 0-100]
                          ring now, e.g. to try a sound:
            meeting-alarm alarm --title Test --start $(date +%s) --max-seconds 10
      watchdog            check the poller has succeeded lately (runs itself)

    SETTINGS
      \(configPath)
      Written by `install`. Leave a key out for the default. Edits apply at the
      next poll; poll_seconds needs `install` again.

      message             "\(d.message)"
                          headline in the window, and the spoken words
      sound               \(soundName)
                          full path to the sound to loop
      fallback_sound      \(fallbackName)
                          used when sound is missing
      volume              \(d.volume)
                          output volume while ringing, 0-100
      speak               \(d.speak)
                          say the message before the sound starts
      break_mute          \(d.breakMute)
                          ring through a muted Mac; false leaves it muted, so
                          only the window appears
      lead_seconds        \(Int(d.leadSeconds))
                          how early it rings
      max_alarm_seconds   \(Int(d.maxAlarmSeconds))
                          seconds after the start to give up; 0 = never
      include_calendars   []
                          calendar titles to watch, e.g. ["Work"]; empty = all.
                          Exact and case-sensitive; `status` flags a name that
                          matches nothing, and lists the unwatched calendars'
                          events as silent.
      expected_source     null
                          account name that must stay signed in, from
                          `calendars`
      poll_seconds        \(Int(d.pollSeconds))
                          seconds between calendar checks, in whole minutes

      Ringtones: /System/Library/PrivateFrameworks/ToneLibrary.framework/
                 Versions/A/Resources/Ringtones/  (also /System/Library/Sounds/)

    GOOGLE CALENDARS
      Add the account under System Settings > Internet Accounts, then set
      Calendar.app > Settings > Accounts > Refresh Calendars to every minute,
      or a meeting added this morning can be missed.

    WHEN SOMETHING GOES WRONG
      Run `meeting-alarm status`; anything wrong is in CAPITALS.
      STALLED
          no poll has succeeded for a while. After sleep, wait a minute and
          check again; otherwise run `meeting-alarm install`
      NO MATCH / NOTHING WILL RING
          fix the include_calendars name it quotes; it suggests near misses

      FAILING, Calendar access denied
          System Settings > Privacy & Security > Calendars, turn on Meeting
          Alarm. Or reset it and get the prompt back:
            tccutil reset Calendar \(Paths.label)
            meeting-alarm install
      FAILING, waiting on a permission prompt
          a Calendar prompt is on screen; click Allow
      NOT LOADED
          run `meeting-alarm install` and read its output
      no events, though you have meetings
          Calendar.app has not synced; see GOOGLE CALENDARS

      Logs: ~/Library/Logs/meeting-alarm/  (poll.log, alarm.log, launchd.log)

    LIMITS
      A meeting only you are on never rings. It cannot tell you already joined.
      The sound follows the selected output device.

    https://github.com/buether/meeting-alarms
    """
}
