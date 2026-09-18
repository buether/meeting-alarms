import AppKit
import Foundation

// Loud, persistent alarm shortly before a calendar meeting starts.
//
// Subcommands:
//   poll      Query upcoming events through EventKit and spawn an alarm for
//             any that are due. launchd runs this every minute.
//   alarm     Loop a sound and show the alarm window until dismissed.
//   test      Arm a one-off alarm for the next poll and kick the launchd job.
//   status    Poller health, recent alarms, and upcoming candidates.
//   calendars Calendar titles and account names EventKit can see.
//   watchdog  Warn if the poller has not succeeded recently.
//   install   Write and load both LaunchAgents for wherever this binary is.
//   uninstall Unload and remove them.

let usage = """
usage: meeting-alarm <command> [options]

  poll [--dry-run] [--now ISO8601] [--events-file PATH]
  alarm --title TITLE --start EPOCH [--url URL] [--max-seconds N] [--volume 0-100]
  test
  status
  calendars
  watchdog [--max-age SECONDS] [--wait SECONDS]
  install
  uninstall
"""

let arguments = Array(CommandLine.arguments.dropFirst())

func option(_ name: String) -> String? {
    guard let i = arguments.firstIndex(of: name), i + 1 < arguments.count else { return nil }
    return arguments[i + 1]
}

func isSet(_ name: String) -> Bool { arguments.contains(name) }

func requireOption(_ name: String) -> String {
    guard let value = option(name) else {
        printErr("\(name) is required\n\n\(usage)")
        exit(64)
    }
    return value
}

/// The alarm and the notice outlive the poll that spawned them.
func detach() { _ = setsid() }

switch arguments.first {
case "poll":
    let now = option("--now").flatMap(parseTimestamp)
    if option("--now") != nil, now == nil {
        printErr("--now is not an ISO 8601 datetime: \(option("--now")!)")
        exit(64)
    }
    exit(poll(dryRun: isSet("--dry-run"), nowOverride: now, eventsFile: option("--events-file")))

case "alarm":
    detach()
    var cfg = Config.load()
    if let maxSeconds = option("--max-seconds").flatMap(Double.init) {
        cfg.maxAlarmSeconds = maxSeconds
    }
    if let volume = option("--volume").flatMap(Int.init) {
        cfg.volume = volume
    }
    guard let startSeconds = Double(requireOption("--start")) else {
        printErr("--start must be epoch seconds")
        exit(64)
    }
    let runner = AlarmRunner(
        cfg: cfg,
        title: requireOption("--title"),
        start: Date(timeIntervalSince1970: startSeconds),
        url: option("--url") ?? ""
    )
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)
    app.delegate = runner
    app.run()

case "notice":
    detach()
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)
    showNotice(
        message: option("--message") ?? "",
        title: option("--title") ?? "Meeting alarm",
        seconds: Double(option("--seconds") ?? "300") ?? 300
    )
    exit(0)

case "test":
    exit(requestTestAlarm())

case "status":
    exit(status())

case "calendars":
    exit(listCalendars())

case "install":
    exit(installAgents())

case "uninstall":
    exit(uninstallAgents())

case "watchdog":
    exit(watchdog(
        maxAge: Double(option("--max-age") ?? "") ?? 3 * 3600,
        wait: Double(option("--wait") ?? "") ?? 90
    ))

case "--help", "-h", "help":
    print(usage)
    exit(0)

default:
    printErr(usage)
    exit(64)
}
