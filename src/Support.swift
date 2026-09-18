import Foundation

// MARK: - Paths

enum Paths {
    static let stateDir = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/meeting-alarm")
    static let logDir = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Logs/meeting-alarm")
    static let statePath = stateDir.appendingPathComponent("state.json")
    static let testFlag = stateDir.appendingPathComponent("test-alarm-requested")
    static let alarmLock = stateDir.appendingPathComponent("alarm.lock")

    /// The launchd job label. Homebrew labels its services `homebrew.mxcl.<name>`,
    /// so `test` and `status` have to be told which job to look at.
    static let label = ProcessInfo.processInfo.environment["MEETING_ALARM_LABEL"]
        ?? "com.buether.meeting-alarm"

    /// Config is looked up outside the install directory: the binary now lives in
    /// a bundle that an upgrade replaces wholesale.
    static var configPath: URL? {
        if let override = ProcessInfo.processInfo.environment["MEETING_ALARM_CONFIG"] {
            return URL(fileURLWithPath: override)
        }
        let supported = stateDir.appendingPathComponent("config.json")
        if FileManager.default.fileExists(atPath: supported.path) { return supported }
        if let repo = repoConfig, FileManager.default.fileExists(atPath: repo.path) { return repo }
        return nil
    }

    /// A checkout run in place keeps its own config.json next to the sources.
    private static var repoConfig: URL? {
        guard let exe = executableURL else { return nil }
        // …/build/MeetingAlarm.app/Contents/MacOS/meeting-alarm -> …/config.json
        let repo = exe.deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        return repo.appendingPathComponent("config.json")
    }

    static var executableURL: URL? {
        Bundle.main.executableURL ?? URL(fileURLWithPath: CommandLine.arguments[0]).standardized
    }
}

// MARK: - Logging

let logRotateBytes = 2_000_000

func log(_ message: String, name: String = "poll") {
    try? FileManager.default.createDirectory(at: Paths.logDir, withIntermediateDirectories: true)
    let path = Paths.logDir.appendingPathComponent("\(name).log")
    let size = (try? FileManager.default.attributesOfItem(atPath: path.path))?[.size] as? Int ?? 0
    if size > logRotateBytes {
        let rotated = Paths.logDir.appendingPathComponent("\(name).log.1")
        try? FileManager.default.removeItem(at: rotated)
        try? FileManager.default.moveItem(at: path, to: rotated)
    }
    let stamp = DateFormatter.logStamp.string(from: Date())
    let line = Data("\(stamp) \(message)\n".utf8)
    if let handle = try? FileHandle(forWritingTo: path) {
        defer { try? handle.close() }
        _ = try? handle.seekToEnd()
        try? handle.write(contentsOf: line)
    } else {
        try? line.write(to: path)
    }
}

extension DateFormatter {
    static let logStamp: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return f
    }()
}

func printErr(_ message: String) {
    FileHandle.standardError.write(Data((message + "\n").utf8))
}

// MARK: - Config

struct Config {
    var leadSeconds: Double = 15
    var pollSeconds: Double = 60
    var maxAlarmSeconds: Double = 900
    var message = "Meeting starting"
    var volume = 75
    var speak = true
    var breakMute = true
    var sound = "/System/Library/PrivateFrameworks/ToneLibrary.framework/Versions/A/Resources/Ringtones/Silk.m4r"
    var fallbackSound = "/System/Library/Sounds/Sosumi.aiff"
    var includeCalendars: [String] = []
    var expectedSource: String?
    var failureNoticeAfterSeconds: Double = 1800
    var failureNoticeEverySeconds: Double = 14400
    var firedRetentionSeconds: Double = 172800

    /// Unreadable config keeps the defaults rather than stopping the poller.
    static func load() -> Config {
        var cfg = Config()
        guard let path = Paths.configPath,
              let data = try? Data(contentsOf: path),
              let raw = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        else { return cfg }

        func double(_ key: String) -> Double? {
            (raw[key] as? NSNumber)?.doubleValue
        }
        cfg.leadSeconds = double("lead_seconds") ?? cfg.leadSeconds
        cfg.pollSeconds = double("poll_seconds") ?? cfg.pollSeconds
        cfg.maxAlarmSeconds = double("max_alarm_seconds") ?? cfg.maxAlarmSeconds
        cfg.message = raw["message"] as? String ?? cfg.message
        cfg.volume = (raw["volume"] as? NSNumber)?.intValue ?? cfg.volume
        cfg.speak = (raw["speak"] as? NSNumber)?.boolValue ?? cfg.speak
        cfg.breakMute = (raw["break_mute"] as? NSNumber)?.boolValue ?? cfg.breakMute
        cfg.sound = raw["sound"] as? String ?? cfg.sound
        cfg.fallbackSound = raw["fallback_sound"] as? String ?? cfg.fallbackSound
        cfg.includeCalendars = raw["include_calendars"] as? [String] ?? cfg.includeCalendars
        cfg.expectedSource = raw["expected_source"] as? String
        cfg.failureNoticeAfterSeconds = double("failure_notice_after_seconds") ?? cfg.failureNoticeAfterSeconds
        cfg.failureNoticeEverySeconds = double("failure_notice_every_seconds") ?? cfg.failureNoticeEverySeconds
        cfg.firedRetentionSeconds = double("fired_retention_seconds") ?? cfg.firedRetentionSeconds
        return cfg
    }

    /// The user-facing settings, written from the defaults so a seeded config
    /// cannot drift from what the binary actually does. The failure-reporting
    /// keys are deliberately left out; they are documented, not everyday.
    var seedJSON: Data? {
        let raw: [String: Any] = [
            "lead_seconds": leadSeconds,
            "poll_seconds": pollSeconds,
            "max_alarm_seconds": maxAlarmSeconds,
            "message": message,
            "volume": volume,
            "speak": speak,
            "break_mute": breakMute,
            "sound": sound,
            "fallback_sound": fallbackSound,
            "include_calendars": includeCalendars,
            "expected_source": expectedSource ?? NSNull(),
        ]
        return try? JSONSerialization.data(
            withJSONObject: raw, options: [.prettyPrinted, .sortedKeys])
    }

    var resolvedSound: String? {
        for candidate in [sound, fallbackSound] where !candidate.isEmpty {
            if FileManager.default.fileExists(atPath: candidate) { return candidate }
        }
        return nil
    }

    /// A missing sound degrades an alarm to one spoken line, which is easy to
    /// mistake for a working one when testing.
    var soundDescription: String {
        guard let resolved = resolvedSound else {
            return "MISSING - the alarm will speak once but not loop"
        }
        let name = URL(fileURLWithPath: resolved).lastPathComponent
        if resolved != sound { return "\(name) (fallback; \(sound) is not on disk)" }
        return name
    }
}

// MARK: - State

struct FiredEvent {
    var at: Double
    var start: Double
    var title: String
}

struct State {
    var fired: [String: FiredEvent] = [:]
    var lastOk: Double?
    var failingSince: Double?
    var lastError: String?
    var lastFailureNotice: Double = 0
    var lastCalendarsCheck: Double = 0
    var polls: Int = 0

    static func load() -> State {
        var state = State()
        guard let data = try? Data(contentsOf: Paths.statePath),
              let raw = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        else { return state }
        if let fired = raw["fired"] as? [String: [String: Any]] {
            for (key, value) in fired {
                state.fired[key] = FiredEvent(
                    at: (value["at"] as? NSNumber)?.doubleValue ?? 0,
                    start: (value["start"] as? NSNumber)?.doubleValue ?? 0,
                    title: value["title"] as? String ?? "(untitled)"
                )
            }
        }
        state.lastOk = (raw["last_ok"] as? NSNumber)?.doubleValue
        state.failingSince = (raw["failing_since"] as? NSNumber)?.doubleValue
        state.lastError = raw["last_error"] as? String
        state.lastFailureNotice = (raw["last_failure_notice"] as? NSNumber)?.doubleValue ?? 0
        state.lastCalendarsCheck = (raw["last_calendars_check"] as? NSNumber)?.doubleValue ?? 0
        state.polls = (raw["polls"] as? NSNumber)?.intValue ?? 0
        return state
    }

    mutating func save(now: Double, cfg: Config) {
        let cutoff = now - cfg.firedRetentionSeconds
        fired = fired.filter { $0.value.start >= cutoff }
        var raw: [String: Any] = [
            "fired": fired.mapValues { ["at": $0.at, "start": $0.start, "title": $0.title] },
            "last_failure_notice": lastFailureNotice,
            "last_calendars_check": lastCalendarsCheck,
            "polls": polls,
        ]
        raw["last_ok"] = lastOk ?? NSNull()
        raw["failing_since"] = failingSince ?? NSNull()
        raw["last_error"] = lastError ?? NSNull()
        try? FileManager.default.createDirectory(at: Paths.stateDir, withIntermediateDirectories: true)
        guard let data = try? JSONSerialization.data(
            withJSONObject: raw, options: [.prettyPrinted, .sortedKeys]
        ) else { return }
        // replaceItemAt needs something to replace, and the first poll has no
        // state file yet.
        let tmp = Paths.statePath.appendingPathExtension("tmp")
        guard (try? data.write(to: tmp)) != nil else { return }
        if FileManager.default.fileExists(atPath: Paths.statePath.path) {
            _ = try? FileManager.default.replaceItemAt(Paths.statePath, withItemAt: tmp)
        } else {
            try? FileManager.default.moveItem(at: tmp, to: Paths.statePath)
        }
    }
}
