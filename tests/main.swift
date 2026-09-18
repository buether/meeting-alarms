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

// MARK: - Report

if failures.isEmpty {
    print("ok - \(checks) checks passed")
    exit(0)
}
print("FAILED - \(failures.count) of \(checks) checks")
for failure in failures { print("  \(failure)") }
exit(1)
