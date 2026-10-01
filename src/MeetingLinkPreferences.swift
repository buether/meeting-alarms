import Foundation

enum MeetingService: String, CaseIterable {
    case googleMeet = "google_meet", zoom, teams, webex, other

    var title: String {
        switch self {
        case .googleMeet: return "Google Meet"
        case .zoom: return "Zoom"
        case .teams: return "Microsoft Teams"
        case .webex: return "Webex"
        case .other: return "Other links"
        }
    }

    static func forURL(_ url: URL) -> MeetingService {
        let scheme = url.scheme?.lowercased()
        guard scheme == "https" || scheme == "http",
              url.port == nil || url.port == (scheme == "https" ? 443 : 80),
              let host = url.host?.lowercased() else { return .other }
        if host == "meet.google.com" { return .googleMeet }
        if host == "zoom.us" || host.hasSuffix(".zoom.us") { return .zoom }
        if ["teams.microsoft.com", "teams.microsoft.us", "teams.live.com"].contains(host) {
            return .teams
        }
        if host == "webex.com" || host.hasSuffix(".webex.com") { return .webex }
        return .other
    }
}

struct MeetingLinkPreferences {
    var applications: [String: String] = [:]

    static var configURL: URL {
        Paths.configPath ?? Paths.stateDir.appendingPathComponent("config.json")
    }

    static func load(at path: URL = configURL) -> MeetingLinkPreferences {
        guard let data = try? Data(contentsOf: path),
              let raw = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let apps = raw["meeting_apps"] as? [String: Any] else {
            return MeetingLinkPreferences()
        }
        return MeetingLinkPreferences(applications: apps.compactMapValues { $0 as? String })
    }

    static func setApplication(_ app: URL?, for service: MeetingService,
                               at path: URL = configURL) throws {
        var raw: [String: Any] = [:]
        if FileManager.default.fileExists(atPath: path.path) {
            let data = try Data(contentsOf: path)
            guard let existing = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw MeetingLinkSettingsError.invalidConfig
            }
            raw = existing
        }
        if let existing = raw["meeting_apps"], !(existing is [String: Any]) {
            throw MeetingLinkSettingsError.invalidConfig
        }
        var apps = raw["meeting_apps"] as? [String: Any] ?? [:]
        apps[service.rawValue] = app?.path
        raw["meeting_apps"] = apps
        let data = try JSONSerialization.data(withJSONObject: raw, options: [.prettyPrinted, .sortedKeys])
        try FileManager.default.createDirectory(at: path.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try data.write(to: path, options: .atomic)
    }

    func application(for url: URL) -> URL? {
        guard let path = applications[MeetingService.forURL(url).rawValue],
              path.hasPrefix("/"), URL(fileURLWithPath: path).pathExtension.lowercased() == "app"
        else { return nil }
        var directory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &directory), directory.boolValue
        else { return nil }
        return URL(fileURLWithPath: path)
    }
}

enum MeetingLinkSettingsError: LocalizedError {
    case invalidConfig

    var errorDescription: String? {
        "The config file is not a JSON object with valid meeting_apps settings. Fix it before saving."
    }
}
