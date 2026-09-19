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

/// Single-quotes a string for the generated shell script.
func shellQuoted(_ value: String) -> String {
    "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
}

/// The script both agents run. It hands off to the binary, or takes the agents
/// down when the binary is gone.
///
/// `brew uninstall` deletes the Cellar and has no hook to run anything on the
/// way out — uninstall directives are a Cask feature, and a formula gets none —
/// so the agents would keep firing every minute at a path that no longer
/// exists. This is the same story for a deleted checkout.
///
/// exec replaces this shell with the bundle executable, so launchd's job
/// process ends up being the signed bundle and macOS still attributes the
/// Calendar request to it.
func agentRunnerScript(executable: String, label: String) -> String {
    """
    #!/bin/bash
    # Written by `meeting-alarm install`. Do not edit; reinstalling overwrites it.
    BIN=\(shellQuoted(executable))
    [ -x "$BIN" ] && exec "$BIN" "$@"

    # The binary is gone. Take the agents down and leave config, history and
    # logs alone.
    LABEL=\(shellQuoted(label))
    AGENTS="$HOME/Library/LaunchAgents"
    # Remove the files before booting out, because booting out this job kills
    # this script mid-run.
    rm -f "$AGENTS/$LABEL.plist" "$AGENTS/$LABEL.watchdog.plist" "$0"
    # Booting out our own job kills this script, so that one goes last.
    case "$1" in
      watchdog) SELF="$LABEL.watchdog"; OTHER="$LABEL" ;;
      *)        SELF="$LABEL";          OTHER="$LABEL.watchdog" ;;
    esac
    launchctl bootout "gui/$(id -u)/$OTHER" 2>/dev/null
    launchctl bootout "gui/$(id -u)/$SELF" 2>/dev/null
    exit 0

    """
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

    /// Lives outside the install directory so it survives whatever removed the
    /// binary, and can clean up after it.
    static var runnerPath: URL {
        Paths.stateDir.appendingPathComponent("run-agent.sh")
    }

    @discardableResult
    static func writeRunner(executable: URL) -> Bool {
        let script = agentRunnerScript(executable: executable.path, label: Paths.label)
        try? FileManager.default.createDirectory(at: Paths.stateDir, withIntermediateDirectories: true)
        guard (try? script.write(to: runnerPath, atomically: true, encoding: .utf8)) != nil,
              (try? FileManager.default.setAttributes([.posixPermissions: 0o755],
                                                      ofItemAtPath: runnerPath.path)) != nil
        else { return false }
        return true
    }

    /// Both agents run `run-agent.sh`, which execs the bundle executable. The
    /// exec keeps the job process on the signed bundle, and the script is what
    /// remains to clean up if the binary is ever removed.
    static func definitions(executable: URL, cfg: Config) -> [(label: String, plist: [String: Any])] {
        let log = Paths.logDir.appendingPathComponent("launchd.log").path
        var poller: [String: Any] = [
            "Label": pollerLabel,
            "ProgramArguments": [runnerPath.path, "poll"],
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
            "ProgramArguments": [runnerPath.path, "watchdog"],
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
    guard Agents.writeRunner(executable: executable) else {
        printErr("could not write \(Agents.runnerPath.path)")
        return 1
    }

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
    try? FileManager.default.removeItem(at: Agents.runnerPath)
    print("Unloaded and removed both LaunchAgents.")
    print("Left in place: \(Paths.stateDir.path) and \(Paths.logDir.path)")
    print("To forget the Calendar grant: tccutil reset Calendar \(Paths.label)")
    return 0
}
