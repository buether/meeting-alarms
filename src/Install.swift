import Foundation

/// Homebrew's Cellar path carries the version number, which an upgrade changes
/// out from under a LaunchAgent. The opt prefix is the stable symlink to
/// whichever version is current, so that is what goes in the plist.
func stablePath(_ url: URL) -> URL {
    let parts = url.pathComponents
    guard let cellar = parts.firstIndex(of: "Cellar"), cellar + 3 <= parts.count - 1 else {
        return url
    }
    let rebuilt = Array(parts[..<cellar]) + ["opt", parts[cellar + 1]] + Array(parts[(cellar + 3)...])
    return URL(fileURLWithPath: NSString.path(withComponents: rebuilt))
}

enum Agents {
    static var pollerLabel: String { Paths.label }
    static var watchdogLabel: String { "\(Paths.label).watchdog" }

    static var directory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents")
    }

    static func plistPath(_ label: String) -> URL {
        directory.appendingPathComponent("\(label).plist")
    }

    /// Both agents run the bundle executable directly, so macOS attributes the
    /// Calendar request to the signed bundle rather than to a shell.
    static func definitions(executable: URL, cfg: Config) -> [(label: String, plist: [String: Any])] {
        let log = Paths.logDir.appendingPathComponent("launchd.log").path
        var poller: [String: Any] = [
            "Label": pollerLabel,
            "ProgramArguments": [executable.path, "poll"],
            "StartInterval": max(1, Int(cfg.pollSeconds)),
            "RunAtLoad": true,
            "ProcessType": "Interactive",
            "LimitLoadToSessionType": "Aqua",
            "AbandonProcessGroup": true,
            "StandardOutPath": log,
            "StandardErrorPath": log,
        ]
        let watchdog: [String: Any] = [
            "Label": watchdogLabel,
            "ProgramArguments": [executable.path, "watchdog"],
            "StartCalendarInterval": [
                ["Hour": 10, "Minute": 5],
                ["Hour": 14, "Minute": 5],
            ],
            "LimitLoadToSessionType": "Aqua",
            "AbandonProcessGroup": true,
            "StandardOutPath": log,
            "StandardErrorPath": log,
        ]
        if Paths.label != "com.buether.meeting-alarm" {
            // A relabelled install has to tell its own agents which label they
            // answer to, or `status` and `test` look at the wrong job.
            poller["EnvironmentVariables"] = ["MEETING_ALARM_LABEL": Paths.label]
        }
        return [(pollerLabel, poller), (watchdogLabel, watchdog)]
    }
}

/// Writes a config file from the built-in defaults when there is none. Under a
/// formula nothing else would create one, leaving nothing to edit.
private func seedConfig() {
    if Paths.configPath != nil { return }
    let path = Paths.stateDir.appendingPathComponent("config.json")
    guard let data = Config().seedJSON else { return }
    try? FileManager.default.createDirectory(at: Paths.stateDir, withIntermediateDirectories: true)
    guard (try? data.write(to: path)) != nil else { return }
    print("Wrote \(path.path)")
}

func installAgents() -> Int32 {
    guard let executable = Paths.executableURL.map(stablePath) else {
        printErr("could not locate the running executable")
        return 1
    }
    let cfg = Config.load()
    seedConfig()

    for directory in [Agents.directory, Paths.logDir] {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    let domain = "gui/\(getuid())"
    for (label, plist) in Agents.definitions(executable: executable, cfg: cfg) {
        let path = Agents.plistPath(label)
        guard let data = try? PropertyListSerialization.data(
            fromPropertyList: plist, format: .xml, options: 0
        ), (try? data.write(to: path)) != nil else {
            printErr("could not write \(path.path)")
            return 1
        }
        _ = launchctl(["bootout", "\(domain)/\(label)"])
        _ = launchctl(["enable", "\(domain)/\(label)"])
        let result = launchctl(["bootstrap", domain, path.path])
        if result.code != 0 {
            printErr("could not load \(label): "
                + result.err.trimmingCharacters(in: .whitespacesAndNewlines))
            return 1
        }
    }
    _ = launchctl(["kickstart", "-k", "\(domain)/\(Agents.pollerLabel)"])

    print("Loaded \(Agents.pollerLabel) (every \(Int(cfg.pollSeconds))s) "
        + "and \(Agents.watchdogLabel) (10:05, 14:05).")
    print("Running: \(executable.path)")
    print("If a Calendar access prompt for 'Meeting Alarm' appears, click Allow.")
    return 0
}

func uninstallAgents() -> Int32 {
    let domain = "gui/\(getuid())"
    for label in [Agents.pollerLabel, Agents.watchdogLabel] {
        _ = launchctl(["bootout", "\(domain)/\(label)"])
        try? FileManager.default.removeItem(at: Agents.plistPath(label))
    }
    print("Unloaded and removed both LaunchAgents.")
    print("Left in place: \(Paths.stateDir.path) and \(Paths.logDir.path)")
    print("To forget the Calendar grant: tccutil reset Calendar \(Paths.label)")
    return 0
}
