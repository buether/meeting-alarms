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
check(runner.contains("$AGENTS/$LABEL.plist") && runner.contains("$AGENTS/$LABEL.watchdog.plist")
      && runner.contains("$AGENTS/$LABEL.menubar.plist"),
      "the runner removes all three plists")
check(runner.contains("\"$0\""), "the runner removes itself")
check(runner.components(separatedBy: "exec \"$BIN\"").count - 1 == 2
      && runner.range(of: "sleep 5")!.lowerBound < runner.range(of: "rm -f")!.lowerBound,
      "the runner looks for the binary twice before removing anything")
check(runner.range(of: "rm -f")!.lowerBound < runner.range(of: "launchctl bootout")!.lowerBound,
      "files go before bootout, which kills the script")
// Booting out our own job kills the script, so the other jobs must go first.
check(runner.range(of: "$OTHER")!.lowerBound < runner.range(of: "$SELF\"")!.lowerBound,
      "the other job is booted out before this one")
check(runner.contains("watchdog) SELF=\"$LABEL.watchdog\"; OTHER=\"$LABEL\"") ||
      runner.contains("watchdog) SELF=\"$LABEL.watchdog\""),
      "the script knows which job it is running as")
check(runner.contains("menubar)  SELF=\"$LABEL.menubar\""),
      "the menu bar runner also unloads itself last")

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

let agentDefinitions = Agents.definitions(executable: URL(fileURLWithPath: "/test/meeting-alarm"), cfg: cfg)
equal(Set(agentDefinitions.map { $0.label }),
      Set([Agents.pollerLabel, Agents.watchdogLabel, Agents.menuBarLabel]),
      "installation includes the poller, watchdog and menu bar")
let menuBarAgent = agentDefinitions.first { $0.label == Agents.menuBarLabel }!.plist
equal(menuBarAgent["ProgramArguments"] as? [String], [Agents.runnerPath.path, "menubar"],
      "the menu bar launches the resident command through the shared runner")
check(menuBarAgent["RunAtLoad"] as? Bool == true && menuBarAgent["KeepAlive"] as? Bool == true,
      "the icon starts on login and is restarted if its process exits")
check(menuBarAgent["StartCalendarInterval"] == nil,
      "the resident menu bar is not launched on each calendar check")
equal(menuBarAgent["LimitLoadToSessionType"] as? String, "Aqua",
      "the menu bar starts only in a graphical login session")
if Paths.label != "com.buether.meeting-alarm" {
    equal((menuBarAgent["EnvironmentVariables"] as? [String: String])?["MEETING_ALARM_LABEL"],
          Paths.label, "the menu bar checks the poller for its own install label")
}

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

// MARK: - Meeting link settings

let appFixtures = FileManager.default.temporaryDirectory
    .appendingPathComponent("meeting-alarm-settings-\(UUID().uuidString)")
let userApps = appFixtures.appendingPathComponent("Applications")
func writeWebApp(_ path: URL, info: [String: Any]) {
    let contents = path.appendingPathComponent("Contents")
    try! FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
    let plist = try! PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
    try! plist.write(to: contents.appendingPathComponent("Info.plist"))
}
let chromeInfo: [String: Any] = [
    "CFBundleIdentifier": "com.google.Chrome.app.test",
    "CrAppModeShortcutID": "saved-meet-app-id",
    "CrAppModeShortcutURL": "https://meet.google.com/landing?lfhs=2",
]
let chromeApp = userApps.appendingPathComponent("Chrome Apps.localized/Work Calls.app")
writeWebApp(chromeApp, info: chromeInfo)
let safariApp = userApps.appendingPathComponent("My Meetings.app")
writeWebApp(safariApp, info: ["CFBundleIdentifier": "com.apple.Safari.WebApp.test"])
let meetLink = URL(string: "https://meet.google.com/abc-defg-hij?authuser=1#join")!
let zoomLink = URL(string: "https://work.zoom.us/j/123?pwd=secret#join")!
let teamsLink = URL(string: "https://teams.microsoft.com/l/meetup-join/test")!
equal(MeetingService.forURL(meetLink), .googleMeet, "Meet selects its own app setting")
equal(MeetingService.forURL(zoomLink), .zoom, "Zoom subdomains select the Zoom setting")
equal(MeetingService.forURL(teamsLink), .teams, "Teams selects its own app setting")
equal(MeetingService.forURL(URL(string: "https://teams.live.com/meet/123")!), .teams,
      "personal Teams meetings use the Teams setting")
equal(MeetingService.forURL(URL(string: "https://teams.microsoft.us/l/meetup-join/123")!), .teams,
      "government Teams meetings use the Teams setting")
equal(MeetingService.forURL(URL(string: "https://work.webex.com/meet/person")!), .webex,
      "Webex subdomains select the Webex setting")
for link in ["https://meet.google.com.example.org/abc", "https://notzoom.us/j/123",
             "file://meet.google.com/abc", "https://meet.google.com:8443/abc"] {
    equal(MeetingService.forURL(URL(string: link)!), .other, "lookalike or non-web links use Other: \(link)")
}
let settingsPath = appFixtures.appendingPathComponent("config.json")
try! Data(#"{"volume":42,"expected_source":"Work","future_key":{"enabled":true}}"#.utf8)
    .write(to: settingsPath)
try! MeetingLinkPreferences.setApplication(safariApp, for: .googleMeet, at: settingsPath)
try! MeetingLinkPreferences.setApplication(chromeApp, for: .zoom, at: settingsPath)
let savedPreferences = MeetingLinkPreferences.load(at: settingsPath)
equal(savedPreferences.application(for: meetLink)?.path, safariApp.path,
      "a saved explicit Meet choice survives reloading")
equal(savedPreferences.application(for: zoomLink)?.path, chromeApp.path,
      "saving Zoom does not overwrite the Meet choice")
check(savedPreferences.application(for: teamsLink) == nil, "unset providers keep the macOS default")
let savedJSON = try! JSONSerialization.jsonObject(with: Data(contentsOf: settingsPath)) as! [String: Any]
equal(savedJSON["volume"] as? Int, 42, "app settings preserve alarm volume")
equal(savedJSON["expected_source"] as? String, "Work", "app settings preserve calendar account settings")
check((savedJSON["future_key"] as? [String: Bool])?["enabled"] == true,
      "app settings preserve unknown config keys")
try! MeetingLinkPreferences.setApplication(nil, for: .googleMeet, at: settingsPath)
check(MeetingLinkPreferences.load(at: settingsPath).application(for: meetLink) == nil,
      "choosing macOS default removes the override")
equal(MeetingLinkPreferences.load(at: settingsPath).application(for: zoomLink)?.path, chromeApp.path,
      "resetting Meet does not reset Zoom")
let newSettings = appFixtures.appendingPathComponent("New/config.json")
try! MeetingLinkPreferences.setApplication(safariApp, for: .googleMeet, at: newSettings)
equal(MeetingLinkPreferences.load(at: newSettings).application(for: meetLink)?.path, safariApp.path,
      "settings can create a config directory on first use")
let corruptSettings = appFixtures.appendingPathComponent("broken.json")
try! Data("broken config".utf8).write(to: corruptSettings)
var refusedCorruptConfig = false
do {
    try MeetingLinkPreferences.setApplication(safariApp, for: .googleMeet, at: corruptSettings)
} catch { refusedCorruptConfig = true }
check(refusedCorruptConfig, "a malformed config is reported instead of overwritten")
equal(try! String(contentsOf: corruptSettings, encoding: .utf8), "broken config",
      "failed saves leave the original config untouched")
check(MeetingLinkPreferences.load(at: corruptSettings).application(for: meetLink) == nil,
      "an unreadable config leaves link handling with macOS")
let invalidPreferences = MeetingLinkPreferences(applications: [
    "google_meet": "relative/Meet.app", "zoom": settingsPath.path,
])
check(invalidPreferences.application(for: meetLink) == nil,
      "relative app paths cannot override the macOS handler")
check(invalidPreferences.application(for: zoomLink) == nil,
      "ordinary files cannot override the macOS handler")
let otherPreferences = MeetingLinkPreferences(applications: ["other": safariApp.path])
equal(otherPreferences.application(for: URL(string: "https://example.org/call")!)?.path,
      safariApp.path, "Other links can have an explicit app choice")
check(otherPreferences.application(for: meetLink) == nil,
      "an Other override does not replace an unset named provider")

var defaultLinks: [URL] = []
var appLinks: [URL] = []
var selectedApps: [URL] = []
var pendingOpen: ((Bool) -> Void)?
var joinCompleted = false
let defaultOpener = MeetingLinkOpener(
    preferences: MeetingLinkPreferences(),
    openDefault: { defaultLinks.append($0) },
    openInApplication: { _, _, _, _ in failures.append("an unset preference must not launch a saved app") }
)
defaultOpener.open(meetLink) { joinCompleted = true }
check(defaultLinks == [meetLink] && joinCompleted,
      "Join respects macOS defaults even when Chrome and Safari Meet apps are installed")
let linkOpener = MeetingLinkOpener(
    preferences: savedPreferences,
    openDefault: { defaultLinks.append($0) },
    openInApplication: { link, app, _, completion in
        appLinks.append(link)
        selectedApps.append(app)
        pendingOpen = completion
    }
)
defaultLinks = []
joinCompleted = false
linkOpener.open(meetLink) { joinCompleted = true }
equal(appLinks, [meetLink], "Join passes the full original URL to the chosen app")
equal(selectedApps.map { $0.path }, [safariApp.path], "an explicit Safari choice wins even with Chrome installed")
check(defaultLinks.isEmpty && !joinCompleted, "Join waits for the chosen app without also opening the default")
pendingOpen?(true)
check(joinCompleted && defaultLinks.isEmpty, "successful chosen-app launch completes Join")
joinCompleted = false
linkOpener.open(meetLink) { joinCompleted = true }
pendingOpen?(false)
check(defaultLinks == [meetLink] && joinCompleted, "a failed chosen app hands the original URL to macOS")
let missingAppPreferences = MeetingLinkPreferences(applications: ["google_meet": "/missing/Meet.app"])
let missingAppOpener = MeetingLinkOpener(preferences: missingAppPreferences,
    openDefault: { defaultLinks.append($0) },
    openInApplication: { _, _, _, _ in failures.append("a removed app must not launch") })
missingAppOpener.open(meetLink) {}
equal(defaultLinks.count, 2, "a removed chosen app falls back to macOS")
linkOpener.open(zoomLink) {}
equal(selectedApps.last?.path, chromeApp.path, "Zoom uses its own explicitly selected app")
pendingOpen?(true)
linkOpener.open(teamsLink) {}
equal(defaultLinks.last, teamsLink, "a Meet override does not affect an unset Teams setting")

let chromeConfiguration = chromeWebAppConfiguration(info: chromeInfo, meetingURL: meetLink)
for channel in ["com.google.Chrome.beta", "com.google.Chrome.canary"] {
    let info: [String: Any] = [
        "CFBundleIdentifier": "\(channel).app.saved-meet-app-id",
        "CrBundleIdentifier": channel,
        "CrAppModeShortcutID": "saved-meet-app-id",
    ]
    equal(chromeWebAppBrowserID(info: info), channel,
          "a selected Chrome channel web app routes through its own browser: \(channel)")
}
check(chromeWebAppBrowserID(info: ["CFBundleIdentifier": "com.google.Chrome.beta",
                                  "CrBundleIdentifier": "com.google.Chrome.beta"]) == nil,
      "a selected native browser receives URLs normally instead of web-app flags")
check(chromeConfiguration?.createsNewApplicationInstance == true,
      "an explicitly chosen Chrome web app receives flags with Chrome already running")
equal(chromeConfiguration?.arguments, [
    "--app-id=saved-meet-app-id",
    "--app-launch-url-for-shortcuts-menu-item=https://meet.google.com/abc-defg-hij?authuser=1#join",
], "a chosen Chrome web app receives the meeting URL rather than its home page")
var profiledChromeInfo = chromeInfo
profiledChromeInfo["CrAppModeUserDataDir"] = "/Users/test/Library/Application Support/Google/Chrome/Profile 2/Web Applications/_crx_saved-meet-app-id"
profiledChromeInfo["CrAppModeProfileDir"] = "Profile 2"
equal(chromeWebAppConfiguration(info: profiledChromeInfo, meetingURL: meetLink)?.arguments, [
    "--app-id=saved-meet-app-id",
    "--app-launch-url-for-shortcuts-menu-item=https://meet.google.com/abc-defg-hij?authuser=1#join",
    "--user-data-dir=/Users/test/Library/Application Support/Google/Chrome",
    "--profile-directory=Profile 2",
], "a chosen Chrome app retains the user data directory and profile recorded by its bundle")
let workProfile = appFixtures.appendingPathComponent("Work Chrome/Profile 8")
try! FileManager.default.createDirectory(at: workProfile, withIntermediateDirectories: true)
try! MeetingLinkPreferences.setChromeProfile(workProfile, for: .zoom, at: settingsPath)
let pinnedPreferences = MeetingLinkPreferences.load(at: settingsPath)
equal(pinnedPreferences.chromeProfilePath(for: zoomLink), workProfile.path,
      "a chosen profile survives saving and reloading")
check(pinnedPreferences.chromeProfilePath(for: meetLink) == nil,
      "a profile choice applies only to its meeting service")
let profileOpener = MeetingLinkOpener(preferences: pinnedPreferences,
    openDefault: { _ in failures.append("an available pinned app must launch") },
    openInApplication: { link, app, profile, completion in
        equal(link, zoomLink, "the pinned app still receives the original URL")
        equal(app.path, chromeApp.path, "a profile does not change the selected app")
        equal(profile, workProfile.path, "Join forwards the selected profile to the app launcher")
        completion(true)
    })
profileOpener.open(zoomLink) {}
equal(chromeWebAppConfiguration(info: profiledChromeInfo, meetingURL: meetLink,
                               profilePath: workProfile.path)?.arguments, [
    "--app-id=saved-meet-app-id",
    "--app-launch-url-for-shortcuts-menu-item=https://meet.google.com/abc-defg-hij?authuser=1#join",
    "--user-data-dir=\(workProfile.deletingLastPathComponent().path)",
    "--profile-directory=Profile 8",
], "an explicit profile overrides a shared shim or its recorded profile and user data root")
for path in ["relative/Profile 8", appFixtures.appendingPathComponent("Missing profile").path,
             settingsPath.path, "/"] {
    check(chromeWebAppConfiguration(info: chromeInfo, meetingURL: meetLink,
                                   profilePath: path) == nil,
          "invalid pinned profiles cannot be passed to Chrome: \(path)")
}
try! MeetingLinkPreferences.setApplication(chromeApp, for: .zoom, at: settingsPath)
equal(MeetingLinkPreferences.load(at: settingsPath).chromeProfilePath(for: zoomLink), workProfile.path,
      "reselecting the same app retains its profile")
try! MeetingLinkPreferences.setChromeProfile(workProfile, for: .googleMeet, at: settingsPath)
try! MeetingLinkPreferences.setApplication(safariApp, for: .zoom, at: settingsPath)
check(MeetingLinkPreferences.load(at: settingsPath).chromeProfilePath(for: zoomLink) == nil,
      "changing an app clears the profile belonging to the previous app")
equal(MeetingLinkPreferences.load(at: settingsPath).chromeProfilePath(for: meetLink), workProfile.path,
      "changing another app preserves the Meet profile")
try! MeetingLinkPreferences.setChromeProfile(nil, for: .googleMeet, at: settingsPath)
check(MeetingLinkPreferences.load(at: settingsPath).chromeProfilePath(for: meetLink) == nil,
      "Chrome chooses profile removes the explicit profile selection")
equal(MeetingLinkPreferences.load(at: settingsPath).application(for: zoomLink)?.path, safariApp.path,
      "resetting a profile retains app selections")
var refusedMissingProfile = false
do {
    try MeetingLinkPreferences.setChromeProfile(appFixtures.appendingPathComponent("Missing"),
                                                for: .googleMeet, at: settingsPath)
} catch { refusedMissingProfile = true }
check(refusedMissingProfile, "settings reject a missing profile without saving it")
let invalidProfileSettings = appFixtures.appendingPathComponent("bad-profiles.json")
let invalidProfileJSON = #"{"meeting_apps":{},"meeting_app_profiles":false,"volume":31}"#
try! Data(invalidProfileJSON.utf8).write(to: invalidProfileSettings)
var refusedBadProfiles = false
do {
    try MeetingLinkPreferences.setChromeProfile(workProfile, for: .googleMeet, at: invalidProfileSettings)
} catch { refusedBadProfiles = true }
check(refusedBadProfiles, "invalid profile settings are reported instead of overwritten")
equal(try! String(contentsOf: invalidProfileSettings, encoding: .utf8), invalidProfileJSON,
      "a failed profile save preserves the complete original config")
let profileJSON = try! JSONSerialization.jsonObject(with: Data(contentsOf: settingsPath)) as! [String: Any]
equal(profileJSON["volume"] as? Int, 42, "profile settings preserve alarm settings")
check((profileJSON["future_key"] as? [String: Bool])?["enabled"] == true,
      "profile settings preserve unknown config keys")
check(isChromeWebApp(at: chromeApp), "the profile selector supports Chrome web apps")
check(!isChromeWebApp(at: safariApp), "Safari apps do not use Chrome profile settings")
var missingID = chromeInfo
missingID.removeValue(forKey: "CrAppModeShortcutID")
check(chromeWebAppConfiguration(info: missingID, meetingURL: meetLink) == nil,
      "incomplete Chrome web-app metadata falls back rather than launching an empty app")
try! FileManager.default.removeItem(at: appFixtures)

var alarmExits: [Int32] = []
var alarmOutcomes: [String] = []
let joiningAlarm = AlarmRunner(cfg: cfg, title: "Join test", start: now, url: meetLink.absoluteString,
                              terminate: { alarmExits.append($0) },
                              recordOutcome: { alarmOutcomes.append($0) })
joiningAlarm.beginJoin()
joiningAlarm.giveUp()
check(alarmExits.isEmpty && alarmOutcomes.isEmpty,
      "the alarm deadline cannot end a pending Join handoff")
joiningAlarm.finish("joined")
equal(alarmExits, [0], "the alarm exits after Join handoff completes")
equal(alarmOutcomes, ["joined"], "a pending Join keeps its outcome when the deadline expires")
joiningAlarm.giveUp()
joiningAlarm.finish("dismissed")
equal(alarmExits, [0], "late finish callbacks cannot exit the alarm twice")

alarmOutcomes = []
let idleAlarm = AlarmRunner(cfg: cfg, title: "Deadline test", start: now, url: "",
                           terminate: { _ in }, recordOutcome: { alarmOutcomes.append($0) })
idleAlarm.giveUp()
equal(alarmOutcomes, ["stopped at max_alarm_seconds"], "an untouched alarm still stops at its deadline")

// MARK: - Report

if failures.isEmpty {
    print("ok - \(checks) checks passed")
    exit(0)
}
print("FAILED - \(failures.count) of \(checks) checks")
for failure in failures { print("  \(failure)") }
exit(1)
