import Foundation

/// Reads and writes config.json without disturbing keys it does not touch, so
/// the settings window and a hand-edited file can share it.
enum ConfigFile {
    static var url: URL {
        Paths.configPath ?? Paths.stateDir.appendingPathComponent("config.json")
    }

    static func update(at path: URL = url, _ change: (inout [String: Any]) throws -> Void) throws {
        var raw: [String: Any] = [:]
        if FileManager.default.fileExists(atPath: path.path) {
            let data = try Data(contentsOf: path)
            guard let existing = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw MeetingLinkSettingsError.invalidConfig
            }
            raw = existing
        }
        try change(&raw)
        let data = try JSONSerialization.data(withJSONObject: raw, options: [.prettyPrinted, .sortedKeys])
        try FileManager.default.createDirectory(at: path.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try data.write(to: path, options: .atomic)
    }

    /// `nil` writes JSON null, which the config reads as "not set".
    static func set(_ key: String, _ value: Any?, at path: URL = url) throws {
        try update(at: path) { $0[key] = value ?? NSNull() }
    }
}

// include_calendars has one trap: an empty list means every calendar. So the
// picker can never write [] by unticking the last box; that is refused, and
// "watch every calendar" is the only way to get [].

/// The list after ticking or unticking one calendar, or nil when that would
/// leave nothing ticked (which would silently mean everything).
func includeAfterToggle(_ current: [String], title: String, on: Bool) -> [String]? {
    var result = current.filter { $0 != title }
    if on { result.append(title) }
    return result.isEmpty ? nil : result.sorted()
}

/// "Watch every calendar" on is []. Off starts from every calendar ticked, so
/// switching it off changes nothing until a box is unticked.
func includeAfterWatchAll(_ on: Bool, allTitles: [String]) -> [String] {
    on ? [] : Array(Set(allTitles)).sorted()
}

/// The poll interval choices offered, plus the current one if it is not among them.
func pollIntervalChoices(current: Double) -> [Int] {
    let minutes = max(1, Int((current / 60).rounded()))
    return Array(Set([1, 2, 5, 10, 15, minutes])).sorted()
}
