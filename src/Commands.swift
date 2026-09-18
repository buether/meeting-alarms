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

func poll(dryRun: Bool, nowOverride: Date?, eventsFile: String?) -> Int32 {
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

func status() -> Int32 {
    let cfg = Config.load()
    let state = State.load()
    let now = Date()

    let printed = launchctl(["print", "gui/\(getuid())/\(Paths.label)"])
    if printed.code != 0 {
        print("launchd: NOT LOADED (run install.sh)")
    } else {
        for line in printed.out.split(separator: "\n") {
            if ["state =", "last exit code =", "runs ="].contains(where: { line.contains($0) }) {
                print("launchd: \(line.trimmingCharacters(in: .whitespaces))")
            }
        }
    }

    func age(_ ts: Double?) -> String {
        guard let ts, ts > 0 else { return "never" }
        return "\(Int(now.timeIntervalSince1970 - ts))s ago"
    }

    print("last successful poll: \(age(state.lastOk))  (polls: \(state.polls))")
    if let failingSince = state.failingSince {
        let since = clockString(Date(timeIntervalSince1970: failingSince), "yyyy-MM-dd HH:mm")
        print("FAILING since \(since): \(state.lastError ?? "unknown error")")
    }
    print("sound: \(cfg.soundDescription)")

    let recent = state.fired.sorted { $0.value.start < $1.value.start }.suffix(5)
    print(recent.isEmpty ? "recent alarms: none" : "recent alarms:")
    for (_, info) in recent {
        let when = clockString(Date(timeIntervalSince1970: info.start), "EEE HH:mm")
        print("  \(when)  \(info.title)")
    }

    let lo = now.addingTimeInterval(-lateLookbackSeconds)
    let hi = now.addingTimeInterval(8 * 3600)
    let events: [Event]
    do {
        events = within(try CalendarStore.events(cfg: cfg, from: lo, to: hi), lo, hi)
    } catch {
        print("calendar query failed: \(error)")
        return 1
    }
    print(events.isEmpty ? "next 8 hours: no events" : "next 8 hours (\(events.count) events):")
    for event in sortByStart(events) {
        let (ok, reason) = event.eligible()
        let fired = state.fired[event.key] != nil
        let verdict = fired ? "fired" : (ok ? "alarm" : "skip")
        let when = clockString(event.startOr(now), "HH:mm")
        print("  \(when)  \(verdict.padding(toLength: 5, withPad: " ", startingAt: 0))  "
              + "\(event.displayTitle)  (\(reason))")
    }
    return 0
}

/// Lists what EventKit can see, for filling in `include_calendars` and
/// `expected_source`.
func listCalendars() -> Int32 {
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
    let width = calendars.map(\.source.count).max() ?? 0
    print("SOURCE".padding(toLength: max(width, 6), withPad: " ", startingAt: 0) + "  CALENDAR")
    for calendar in calendars.sorted(by: { ($0.source, $0.title) < ($1.source, $1.title) }) {
        let source = calendar.source.padding(toLength: max(width, 6), withPad: " ", startingAt: 0)
        print("\(source)  \(calendar.title)")
    }
    return 0
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
