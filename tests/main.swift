import Foundation

// Port of tests/test_select_due.py. Built as its own binary against the same
// sources, so it needs no test framework outside the Command Line Tools.

var checks = 0
var failures: [String] = []

func check(_ condition: Bool, _ name: String) {
    checks += 1
    if !condition { failures.append(name) }
}

func equal<T: Equatable>(_ actual: T, _ expected: T, _ name: String) {
    checks += 1
    if actual != expected {
        failures.append("\(name): expected \(expected), got \(actual)")
    }
}

func unequal<T: Equatable>(_ actual: T, _ other: T, _ name: String) {
    checks += 1
    if actual == other { failures.append("\(name): both were \(actual)") }
}

let now = Date(timeIntervalSince1970: 1_800_000_000)
let cfg: Config = {
    var c = Config()
    c.leadSeconds = 60
    c.pollSeconds = 60
    return c
}()

func makeEvent(
    _ startOffset: Double,
    duration: Double = 1800,
    me: String? = "accepted",
    others: Bool = true,
    allDay: Bool = false,
    status: String = "confirmed",
    id: String? = "abc",
    title: String? = "Standup",
    at: Date = now,
    unreadableStart: Bool = false,
    noEnd: Bool = false,
    noAttendees: Bool = false
) -> Event {
    var attendees: [Attendee]? = []
    if others {
        attendees?.append(Attendee(email: "them@example.com", status: "accepted", isCurrentUser: false))
    }
    if let me {
        attendees?.append(Attendee(email: "me@example.com", status: me, isCurrentUser: true))
    }
    if noAttendees { attendees = nil }
    let start = at.addingTimeInterval(startOffset)
    return Event(
        id: id,
        title: title,
        startDate: unreadableStart ? nil : start,
        endDate: noEnd ? nil : start.addingTimeInterval(duration),
        isAllDay: allDay,
        status: status,
        attendees: attendees
    )
}

func fires(_ event: Event, fired: [String: FiredEvent] = [:]) -> Bool {
    event.classify(now: now, fired: fired, cfg: cfg).fire
}

let firedMarker = FiredEvent(at: 0, start: 0, title: "")

// MARK: - Window

check(fires(makeEvent(119)), "fires just inside lead plus poll")
check(!fires(makeEvent(120)), "does not fire at lead plus poll")
check(fires(makeEvent(59)), "fires when poll ran late")
check(fires(makeEvent(-3600, duration: 7200)), "fires long after start while still running")
check(!fires(makeEvent(-100, duration: 60)), "does not fire after meeting ended")
check(!fires(makeEvent(-7201, duration: 7200)), "does not fire once a long meeting ends")

// MARK: - Dedupe

let repeated = makeEvent(90)
check(!fires(repeated, fired: [repeated.key: firedMarker]), "already fired key is skipped")
unequal(makeEvent(90).key, makeEvent(690).key, "moved meeting gets new key")
unequal(makeEvent(90, id: "recurring").key,
        makeEvent(90 + 86400, id: "recurring").key,
        "recurring occurrences differ by start")
equal(Set(selectDue([makeEvent(90, id: "a"), makeEvent(95, id: "b")],
                    now: now, fired: [:], cfg: cfg).map { $0.id ?? "" }),
      ["a", "b"],
      "two meetings in the same minute are both due")

// MARK: - Filters

check(!fires(makeEvent(90, allDay: true)), "all-day skipped")
check(!fires(makeEvent(90, status: "canceled")), "canceled skipped")
check(!fires(makeEvent(90, others: false)), "solo event skipped")
check(!fires(makeEvent(90, me: "declined")), "declined skipped")
check(!fires(makeEvent(90, me: "tentative")), "tentative skipped")
check(fires(makeEvent(90, me: "pending")), "pending fires")
check(fires(makeEvent(90, me: "unknown")), "unknown status fires")
check(fires(makeEvent(90, me: nil)), "no current-user attendee fires")
check(makeEvent(90, me: "pending").classify(now: now, fired: [:], cfg: cfg).reason.contains("pending"),
      "reason names my status")

// MARK: - Within

let window = fireWindow(now: now, cfg: cfg)
let spread = [
    makeEvent(-(lateLookbackSeconds + 1), id: "early"),
    makeEvent(-500, id: "in"),
    makeEvent(200, id: "late"),
]
equal(within(spread, window.lo, window.hi).map { $0.id ?? "" }, ["in"],
      "keeps only starts inside the window")
equal(within([makeEvent(window.hi.timeIntervalSince(now))], window.lo, window.hi).count, 0,
      "upper bound is exclusive")

// MARK: - Fail-safe
// An unreadable event alarms; only a known end time in the past is silent.

check(fires(makeEvent(90, title: nil)), "missing title fires")
check(fires(makeEvent(90, title: "")), "empty title fires")
equal(makeEvent(90, title: nil).displayTitle, "(untitled)", "missing title displays as untitled")
check(fires(makeEvent(90, noEnd: true)), "missing end date fires")
check(fires(makeEvent(90, unreadableStart: true)), "unreadable start fires")

// A key that changed per poll would alarm every 60 seconds.
let firstUnreadable = makeEvent(90, unreadableStart: true)
let secondUnreadable = makeEvent(90, unreadableStart: true)
equal(firstUnreadable.key, secondUnreadable.key, "unreadable start keeps a stable key")
check(!fires(secondUnreadable, fired: [firstUnreadable.key: firedMarker]),
      "unreadable start does not re-fire")

check(fires(makeEvent(90, noAttendees: true)), "missing attendees fires")
check(!fires(makeEvent(90, me: nil, others: false)), "explicitly empty attendees is skipped")
equal(within([makeEvent(90, unreadableStart: true)], window.lo, window.hi).count, 1,
      "within keeps an unreadable start")

// MARK: - Timestamps

equal(parseTimestamp("2026-09-15T21:00:00Z")?.timeIntervalSince1970, 1_789_506_000,
      "parses zulu")
equal(parseTimestamp("2026-09-15T14:00:00-07:00")?.timeIntervalSince1970, 1_789_506_000,
      "parses offset")
equal(parseTimestamp("2026-09-15T21:00:00.500Z")?.timeIntervalSince1970, 1_789_506_000.5,
      "parses fractional seconds")
check(parseTimestamp("not-a-date") == nil, "rejects nonsense")

// MARK: - Volume restore

let wasMuted = VolumeSetting(level: 88, muted: true)
let wasLoud = VolumeSetting(level: 88, muted: false)
let untouched = VolumeSetting(level: 75, muted: false)   // still where the alarm put it
let movedByHand = VolumeSetting(level: 30, muted: false)

equal(volumeRestore(saved: wasLoud, current: untouched, alarmLevel: 75), wasLoud,
      "untouched output goes back to what it was")
equal(volumeRestore(saved: wasMuted, current: untouched, alarmLevel: 75), wasMuted,
      "an output the alarm unmuted goes back to muted")
check(volumeRestore(saved: wasLoud, current: movedByHand, alarmLevel: 75) == nil,
      "a hand-set level is left alone")
check(volumeRestore(saved: wasMuted, current: VolumeSetting(level: 75, muted: true),
                    alarmLevel: 75) == nil,
      "an output muted again by hand is left alone")
check(volumeRestore(saved: wasMuted, current: nil, alarmLevel: 75) == nil,
      "a device with no software volume is left alone")

// MARK: - Agent paths
// A Cellar path carries the version, which brew upgrade changes out from under
// a LaunchAgent; opt is the stable symlink to whatever version is current.

equal(stablePath(URL(fileURLWithPath:
        "/opt/homebrew/Cellar/meeting-alarm/1.0.0/libexec/MeetingAlarm.app/Contents/MacOS/meeting-alarm")).path,
      "/opt/homebrew/opt/meeting-alarm/libexec/MeetingAlarm.app/Contents/MacOS/meeting-alarm",
      "a Cellar path is rewritten through opt")
equal(stablePath(URL(fileURLWithPath:
        "/usr/local/Cellar/meeting-alarm/2.3.1/libexec/MeetingAlarm.app/Contents/MacOS/meeting-alarm")).path,
      "/usr/local/opt/meeting-alarm/libexec/MeetingAlarm.app/Contents/MacOS/meeting-alarm",
      "the Intel prefix works too")
equal(stablePath(URL(fileURLWithPath:
        "/Users/someone/src/meeting-alarms/build/MeetingAlarm.app/Contents/MacOS/meeting-alarm")).path,
      "/Users/someone/src/meeting-alarms/build/MeetingAlarm.app/Contents/MacOS/meeting-alarm",
      "a checkout path is left alone")
equal(stablePath(URL(fileURLWithPath: "/tmp/Cellar")).path, "/tmp/Cellar",
      "a path that ends at Cellar is left alone")

// MARK: - Agent runner script

equal(shellQuoted("/opt/homebrew/opt/meeting-alarm/libexec/x"),
      "'/opt/homebrew/opt/meeting-alarm/libexec/x'", "an ordinary path is quoted")
equal(shellQuoted("/Users/o'brien/src/x"), "'/Users/o'\\''brien/src/x'",
      "an apostrophe in a path is escaped")

let runner = agentRunnerScript(executable: "/opt/homebrew/opt/meeting-alarm/libexec/bin",
                               label: "homebrew.mxcl.meeting-alarm")
check(runner.hasPrefix("#!/bin/bash\n"), "the runner is a bash script")
check(runner.contains("BIN='/opt/homebrew/opt/meeting-alarm/libexec/bin'"),
      "the runner quotes the binary path")
check(runner.contains("[ -x \"$BIN\" ] && exec \"$BIN\" \"$@\""),
      "the runner execs the binary when it is there")
check(runner.contains("LABEL='homebrew.mxcl.meeting-alarm'"), "the runner quotes the label")
check(runner.contains("$AGENTS/$LABEL.plist") && runner.contains("$AGENTS/$LABEL.watchdog.plist"),
      "the runner removes both plists")
check(runner.contains("\"$0\""), "the runner removes itself")
check(runner.components(separatedBy: "exec \"$BIN\"").count - 1 == 2
      && runner.range(of: "sleep 5")!.lowerBound < runner.range(of: "rm -f")!.lowerBound,
      "the runner looks for the binary twice before removing anything")
check(runner.range(of: "rm -f")!.lowerBound < runner.range(of: "launchctl bootout")!.lowerBound,
      "files go before bootout, which kills the script")
// Booting out our own job kills the script, so the other job has to go first
// or it is left loaded with no plist behind it.
check(runner.range(of: "$OTHER")!.lowerBound < runner.range(of: "$SELF\"")!.lowerBound,
      "the other job is booted out before this one")
check(runner.contains("watchdog) SELF=\"$LABEL.watchdog\"; OTHER=\"$LABEL\"") ||
      runner.contains("watchdog) SELF=\"$LABEL.watchdog\""),
      "the script knows which job it is running as")

// MARK: - Poll schedule
// StartCalendarInterval, because launchd can hold StartInterval jobs forever.

check((pollSchedule(pollSeconds: 60) as? [String: Int])?.isEmpty == true,
      "sixty seconds is every minute")
check((pollSchedule(pollSeconds: 10) as? [String: Int])?.isEmpty == true,
      "under a minute rounds up to every minute")
equal((pollSchedule(pollSeconds: 300) as? [[String: Int]])?.map { $0["Minute"]! } ?? [],
      [0, 5, 10, 15, 20, 25, 30, 35, 40, 45, 50, 55], "five minutes is every fifth minute")
equal((pollSchedule(pollSeconds: 130) as? [[String: Int]])?.count ?? 0, 30,
      "a little over two minutes rounds to every second minute")

// MARK: - Status report
// status is the only place a user checks their setup, so config mistakes have
// to be visible in its output rather than in a notice nobody remembers.

let cals = [
    CalendarInfo(title: "Work", source: "Google"),
    CalendarInfo(title: "Family", source: "Google"),
    CalendarInfo(title: "Birthdays", source: "Other", neverRings: true),
]
let allPlan = planCalendars(cals, include: [])
equal(allPlan.watchedTitles, ["Work", "Family"], "empty include_calendars watches every calendar that can ring")
check(allPlan.unmatched.isEmpty, "empty include_calendars has nothing unmatched")
equal(allPlan.rows.first { $0.calendar.title == "Birthdays" }?.watch, .neverRings,
      "birthdays never ring even when everything is watched")

let workPlan = planCalendars(cals, include: ["Work"])
equal(workPlan.watchedTitles, ["Work"], "include_calendars watches only what it names")
equal(workPlan.rows.first { $0.calendar.title == "Family" }?.watch, .notListed,
      "an unnamed calendar is shown as not watched, not hidden")
equal(workPlan.rows.first?.calendar.title, "Work", "watched calendars list first")

let typoPlan = planCalendars(cals, include: ["work"])
check(typoPlan.watchedTitles.isEmpty, "a wrong-case name watches nothing")
equal(typoPlan.unmatched.map(\.name), ["work"], "a wrong-case name is reported")
equal(typoPlan.unmatched.first?.nearMiss, "Work", "a wrong-case name suggests the real one")
equal(planCalendars(cals, include: ["Birthdays"]).unmatched.map(\.name), ["Birthdays"],
      "naming a calendar that never rings is reported")
check(planCalendars(cals, include: ["Nope"]).unmatched.first?.nearMiss == nil,
      "no suggestion when nothing is close")

var workEvent = makeEvent(600)
workEvent.calendar = "Work"
var familyEvent = makeEvent(600, id: "f")
familyEvent.calendar = "Family"
equal(verdict(for: workEvent, now: now, fired: [:], watchedTitles: ["Work"]).verdict, .rings,
      "an eligible event in a watched calendar rings")
equal(verdict(for: familyEvent, now: now, fired: [:], watchedTitles: ["Work"]).reason,
      "calendar not watched", "an event in an unwatched calendar says why it is silent")
equal(verdict(for: workEvent, now: now, fired: [workEvent.key: firedMarker], watchedTitles: ["Work"]).verdict,
      .rang, "an event that already rang says so")
var running = makeEvent(-120, duration: 1800)
running.calendar = "Work"
check(verdict(for: running, now: now, fired: [:], watchedTitles: ["Work"]).reason.hasSuffix("in progress"),
      "a meeting under way is marked in progress")
equal(verdict(for: makeEvent(600, me: "declined"), now: now, fired: [:], watchedTitles: []).verdict,
      .silent, "a declined event with no calendar recorded is still judged on its own merits")

let t = now.timeIntervalSince1970
check(pollerHealth(loaded: true, lastOk: t - 30, failingSince: nil, lastError: nil,
                   now: t, pollSeconds: 60).ok, "a poll 30s ago is healthy")
let stalled = pollerHealth(loaded: true, lastOk: t - 11 * 86400, failingSince: nil, lastError: nil,
                           now: t, pollSeconds: 60)
check(!stalled.ok && stalled.line.hasPrefix("STALLED") && stalled.line.contains("11 days"),
      "a poller silent for eleven days reads as stalled, whatever launchd says")
check(pollerHealth(loaded: false, lastOk: t - 30, failingSince: nil, lastError: nil,
                   now: t, pollSeconds: 60).line.hasPrefix("NOT LOADED"), "unloaded agents are reported")
check(pollerHealth(loaded: true, lastOk: t - 30, failingSince: t - 60, lastError: "denied",
                   now: t, pollSeconds: 60).line.hasPrefix("FAILING"), "a failing poller is reported")
check(pollerHealth(loaded: true, lastOk: nil, failingSince: nil, lastError: nil,
                   now: t, pollSeconds: 60).line.hasPrefix("NEVER RUN"), "a poller that never succeeded is reported")
equal(humanAge(45), "45s", "seconds read as seconds")
equal(humanAge(11 * 86400), "11 days", "days read as days")

// MARK: - Report

if failures.isEmpty {
    print("ok - \(checks) checks passed")
    exit(0)
}
print("FAILED - \(failures.count) of \(checks) checks")
for failure in failures { print("  \(failure)") }
exit(1)
