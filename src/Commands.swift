import AppKit
import Foundation

// MARK: - Spawning

/// Runs a subcommand of this same binary and returns immediately. The child
/// calls setsid() for itself so a `launchctl kickstart -k` cannot take it down.
@discardableResult
func spawnSelf(_ arguments: [String], logName: String?) -> Bool {
    guard let executable = Paths.executableURL else { return false }
    let process = Process()
    process.executableURL = executable
    process.arguments = arguments
    process.standardInput = FileHandle.nullDevice
    if let logName {
        try? FileManager.default.createDirectory(at: Paths.logDir, withIntermediateDirectories: true)
        let path = Paths.logDir.appendingPathComponent("\(logName).log")
        if !FileManager.default.fileExists(atPath: path.path) {
            FileManager.default.createFile(atPath: path.path, contents: nil)
        }
        if let handle = try? FileHandle(forWritingTo: path) {
            _ = try? handle.seekToEnd()
            process.standardOutput = handle
            process.standardError = handle
        }
    } else {
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
    }
    do { try process.run() } catch { return false }
    return true
}

func notify(_ message: String, title: String = "Meeting alarm", seconds: Int = 300) {
    spawnSelf(["notice", "--message", message, "--title", title, "--seconds", String(seconds)],
              logName: nil)
}

@discardableResult
func launchctl(_ arguments: [String]) -> (code: Int32, out: String, err: String) {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
    process.arguments = arguments
    let outPipe = Pipe(), errPipe = Pipe()
    process.standardOutput = outPipe
    process.standardError = errPipe
    do { try process.run() } catch { return (127, "", "launchctl not available") }
    let out = String(decoding: outPipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
    let err = String(decoding: errPipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
    process.waitUntilExit()
    return (process.terminationStatus, out, err)
}

// MARK: - poll

func maybeNotifyFailure(state: inout State, now: Date, cfg: Config) {
    guard let failingSince = state.failingSince else { return }
    let failingFor = now.timeIntervalSince1970 - failingSince
    let sinceNotice = now.timeIntervalSince1970 - state.lastFailureNotice
    if failingFor < cfg.failureNoticeAfterSeconds { return }
    if sinceNotice < cfg.failureNoticeEverySeconds { return }
    let since = clockString(Date(timeIntervalSince1970: failingSince), "HH:mm")
    notify("""
        Meeting alarm has not been able to read the calendar since \(since).

        \(state.lastError ?? "unknown error")

        Run: meeting-alarm status
        """)
    state.lastFailureNotice = now.timeIntervalSince1970
}

func spawnAlarm(_ due: [Event], now: Date) {
    let title = due.map(\.displayTitle).joined(separator: "; ")
    let start = due.compactMap(\.startDate).min() ?? now
    let url = due.compactMap(\.meetingURL).first { !$0.isEmpty } ?? ""
    spawnSelf(["alarm",
               "--title", title,
               "--start", String(Int(start.timeIntervalSince1970)),
               "--url", url],
              logName: "alarm")
}

private var pollDeadline: DispatchSourceTimer?

/// A poll that never returns wedges the job for good: launchd will not start
/// the next one while this one is still running. EventKit's calls into tccd
/// have no timeout of their own while a permission prompt sits unanswered, and
/// that once stopped every poll for eleven days with only the watchdog noticing.
/// So the whole poll gets a deadline, and missing it counts as a failure like
/// any other, which is what eventually raises the failure notice.
func armPollDeadline(dryRun: Bool) {
    let seconds = Double(ProcessInfo.processInfo.environment["MEETING_ALARM_POLL_DEADLINE"] ?? "")
        ?? 150
    let timer = DispatchSource.makeTimerSource(queue: .global())
    timer.schedule(deadline: .now() + seconds)
    timer.setEventHandler {
        let message = "poll still running after \(Int(seconds))s "
            + "(waiting on a Calendar permission prompt?); exiting so the next one can start"
        if !dryRun {
            let cfg = Config.load()
            let now = Date()
            var state = State.load()
            state.lastError = message
            state.failingSince = state.failingSince ?? now.timeIntervalSince1970
            maybeNotifyFailure(state: &state, now: now, cfg: cfg)
            state.save(now: now.timeIntervalSince1970, cfg: cfg)
        }
        log("FAIL \(message)")
        printErr("FAIL \(message)")
        // Not exit(): its teardown could block on whatever the poll is stuck in.
        _exit(2)
    }
    timer.resume()
    pollDeadline = timer
}

func poll(dryRun: Bool, nowOverride: Date?, eventsFile: String?) -> Int32 {
    armPollDeadline(dryRun: dryRun)
    let cfg = Config.load()
    let now = nowOverride ?? Date()
    var state = State.load()
    state.polls += 1

    var events: [Event]
    do {
        if let eventsFile {
            events = try Event.load(fixture: eventsFile)
        } else {
            let window = fireWindow(now: now, cfg: cfg)
            events = try CalendarStore.events(cfg: cfg, from: window.lo, to: window.hi)
        }
        // EventKit matches events overlapping the window, so one that started
        // before the lookback comes back too.
        let window = fireWindow(now: now, cfg: cfg)
        events = within(events, window.lo, window.hi)
        if cfg.expectedSource != nil,
           now.timeIntervalSince1970 - state.lastCalendarsCheck > 3600 {
            try CalendarStore.checkCalendars(cfg: cfg)
            state.lastCalendarsCheck = now.timeIntervalSince1970
        }
    } catch {
        let message = "\(error)"
        state.lastError = message
        state.failingSince = state.failingSince ?? now.timeIntervalSince1970
        maybeNotifyFailure(state: &state, now: now, cfg: cfg)
        if !dryRun { state.save(now: now.timeIntervalSince1970, cfg: cfg) }
        log("FAIL \(message)")
        printErr("FAIL \(message)")
        return 1
    }

    state.lastOk = now.timeIntervalSince1970
    state.failingSince = nil
    state.lastError = nil

    var due = selectDue(events, now: now, fired: state.fired, cfg: cfg)

    if dryRun {
        for event in sortByStart(events) {
            let (fire, reason) = event.classify(now: now, fired: state.fired, cfg: cfg)
            let when = localISO(event.startOr(now))
            print("\(fire ? "FIRE" : "skip")  \(when)  \(event.displayTitle)  (\(reason))")
        }
        print("\(events.count) events in window, \(due.count) due")
        return 0
    }

    if FileManager.default.fileExists(atPath: Paths.testFlag.path) {
        try? FileManager.default.removeItem(at: Paths.testFlag)
        due.append(Event(
            id: "test",
            title: "TEST ALARM",
            startDate: now.addingTimeInterval(cfg.leadSeconds),
            meetingURL: "https://meet.google.com/"
        ))
    }

    log("ok events=\(events.count) due=\(due.map(\.key))")
    if !due.isEmpty {
        spawnAlarm(due, now: now)
        for event in due {
            state.fired[event.key] = FiredEvent(
                at: now.timeIntervalSince1970,
                start: event.startOr(now).timeIntervalSince1970,
                title: event.displayTitle
            )
        }
    }
    state.save(now: now.timeIntervalSince1970, cfg: cfg)
    return 0
}

// MARK: - test / status / watchdog

func requestTestAlarm() -> Int32 {
    try? FileManager.default.createDirectory(at: Paths.stateDir, withIntermediateDirectories: true)
    FileManager.default.createFile(atPath: Paths.testFlag.path, contents: nil)
    let result = launchctl(["kickstart", "-k", "gui/\(getuid())/\(Paths.label)"])
    if result.code != 0 {
        print("kickstart failed: \(result.err.trimmingCharacters(in: .whitespacesAndNewlines))")
        print("The test alarm will fire on the next scheduled poll instead.")
        return 1
    }
    print("Test alarm requested. It should ring within a few seconds.")
    return 0
}

func pad(_ text: String, _ width: Int) -> String {
    let clipped = text.count > width ? String(text.prefix(width - 1)) + "…" : text
    return clipped.padding(toLength: width, withPad: " ", startingAt: 0)
}

/// Prints the calendar table shared by `status` and `calendars`, and returns
/// whether include_calendars has a problem.
@discardableResult
func printCalendarPlan(_ plan: CalendarPlan, cfg: Config) -> Bool {
    let eligible = plan.rows.filter { $0.watch != .neverRings }.count
    if cfg.includeCalendars.isEmpty {
        print("CALENDARS  watching all \(eligible)  (include_calendars is empty)")
    } else {
        let names = cfg.includeCalendars.map { "\"\($0)\"" }.joined(separator: ", ")
        print("CALENDARS  watching \(plan.rows.filter { $0.watch == .watched }.count) of \(eligible)  (include_calendars: [\(names)])")
    }
    let width = min(24, plan.rows.map { $0.calendar.source.count }.max() ?? 0)
    for (calendar, watch) in plan.rows {
        let label = ["watched", "not watched", "never rings"][[CalendarWatch.watched, .notListed, .neverRings].firstIndex(of: watch)!]
        print("  \(pad(label, 12)) \(pad(calendar.source, max(width, 6)))  \(calendar.title)")
    }
    for miss in plan.unmatched {
        if plan.rows.contains(where: { $0.watch == .neverRings && $0.calendar.title == miss.name }) {
            print("  NO MATCH   include_calendars lists \"\(miss.name)\", a birthday or subscribed calendar. Those have no attendees, so they never ring.")
            continue
        }
        let hint = miss.nearMiss.map { " Did you mean \"\($0)\"? Names are case-sensitive." } ?? ""
        print("  NO MATCH   include_calendars lists \"\(miss.name)\", but no calendar that can ring is called that.\(hint)")
    }
    if !cfg.includeCalendars.isEmpty && plan.rows.allSatisfy({ $0.watch != .watched }) {
        print("  NOTHING WILL RING: include_calendars matches none of your calendars.")
    }
    return !plan.unmatched.isEmpty
}

func status(eventsFile: String? = nil) -> Int32 {
    let cfg = Config.load()
    let state = State.load()
    let now = Date()
    var problems = 0

    let loaded = launchctl(["print", "gui/\(getuid())/\(Paths.label)"]).code == 0
    let health = pollerHealth(loaded: loaded, lastOk: state.lastOk, failingSince: state.failingSince,
                              lastError: state.lastError, now: now.timeIntervalSince1970,
                              pollSeconds: cfg.pollSeconds)
    if !health.ok { problems += 1 }
    print("POLLER     \(health.line)")
    let sound = cfg.soundDescription
    if cfg.resolvedSound == nil { problems += 1 }
    print("SOUND      \(sound)")
    print("CONFIG     \(Paths.configPath?.path.replacingOccurrences(of: FileManager.default.homeDirectoryForCurrentUser.path, with: "~") ?? "none - built-in defaults")")

    let calendars: [CalendarInfo]
    let events: [Event]
    let lo = now.addingTimeInterval(-lateLookbackSeconds)
    let hi = now.addingTimeInterval(8 * 3600)
    do {
        if let eventsFile {
            // A recorded day: its calendars are whatever its events name.
            events = within(try Event.load(fixture: eventsFile), lo, hi)
            calendars = Set(events.compactMap(\.calendar)).sorted().map {
                CalendarInfo(title: $0, source: "fixture")
            }
        } else {
            calendars = try CalendarStore.calendars()
            events = within(try CalendarStore.events(cfg: cfg, from: lo, to: hi, onlyWatched: false),
                            lo, hi)
        }
    } catch {
        print("")
        print("CALENDAR   query failed - nothing will ring. \(error)")
        return 1
    }

    print("")
    let plan = planCalendars(calendars, include: cfg.includeCalendars)
    if printCalendarPlan(plan, cfg: cfg) { problems += 1 }

    // Ended meetings are history, not a prediction.
    let upcoming = sortByStart(events.filter { event in
        guard let end = event.endDate else { return true }
        return end > now
    })
    let verdicts = upcoming.map {
        ($0, verdict(for: $0, now: now, fired: state.fired, watchedTitles: plan.watchedTitles))
    }
    let ringing = verdicts.filter { $0.1.verdict == .rings }.count
    print("")
    if upcoming.isEmpty {
        print("NEXT 8 HOURS  no events in any calendar")
    } else {
        print("NEXT 8 HOURS  \(ringing) will ring, \(upcoming.count - ringing) will not")
    }
    let calendarWidth = min(20, upcoming.compactMap(\.calendar).map(\.count).max() ?? 0)
    for (event, result) in verdicts {
        let when = whenColumn(event, now: now)
        print("  \(pad(when, 9)) \(pad(result.verdict.rawValue, 6)) \(pad(event.displayTitle, 30)) "
            + "\(pad(event.calendar ?? "", max(calendarWidth, 8)))  \(result.reason)")
    }

    let recent = state.fired.sorted { $0.value.start < $1.value.start }.suffix(5)
    print("")
    print(recent.isEmpty ? "RECENT ALARMS  none" : "RECENT ALARMS")
    for (_, info) in recent {
        print("  \(clockString(Date(timeIntervalSince1970: info.start), "EEE HH:mm"))  \(info.title)")
    }

    print("")
    print(problems == 0 ? "No problems found." : "\(problems) problem\(problems == 1 ? "" : "s") above, in capitals.")
    return problems == 0 ? 0 : 1
}

/// Lists what EventKit can see, and which of it the poller watches.
func listCalendars() -> Int32 {
    let cfg = Config.load()
    let calendars: [CalendarInfo]
    do {
        calendars = try CalendarStore.calendars()
    } catch {
        printErr("calendar query failed: \(error)")
        return 1
    }
    if calendars.isEmpty {
        print("no calendars")
        return 0
    }
    return printCalendarPlan(planCalendars(calendars, include: cfg.includeCalendars), cfg: cfg) ? 1 : 0
}

func watchdog(maxAge: Double, wait: Double) -> Int32 {
    if wait > 0 { Thread.sleep(forTimeInterval: wait) }
    let state = State.load()
    let now = Date().timeIntervalSince1970
    if let lastOk = state.lastOk, now - lastOk <= maxAge {
        log("watchdog: ok")
        return 0
    }
    let last = state.lastOk.map {
        clockString(Date(timeIntervalSince1970: $0), "yyyy-MM-dd HH:mm")
    } ?? "never"
    notify("Meeting alarm poller has not succeeded since \(last).\n\nRun: meeting-alarm status")
    log("watchdog: stale, last_ok=\(last)")
    return 1
}
