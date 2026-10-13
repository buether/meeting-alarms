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
    var chromeProfiles: [String: String] = [:]

    static var configURL: URL {
        Paths.configPath ?? Paths.stateDir.appendingPathComponent("config.json")
    }

    static func load(at path: URL = configURL) -> MeetingLinkPreferences {
        guard let data = try? Data(contentsOf: path),
              let raw = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            return MeetingLinkPreferences()
        }
        return MeetingLinkPreferences(
            applications: (raw["meeting_apps"] as? [String: Any] ?? [:]).compactMapValues { $0 as? String },
            chromeProfiles: (raw["meeting_app_profiles"] as? [String: Any] ?? [:]).compactMapValues { $0 as? String }
        )
    }

    static func setApplication(_ app: URL?, for service: MeetingService,
                               at path: URL = configURL) throws {
        try updateConfig(at: path) { raw in
            var apps = raw["meeting_apps"] as? [String: Any] ?? [:]
            if apps[service.rawValue] as? String != app?.path {
                var profiles = raw["meeting_app_profiles"] as? [String: Any] ?? [:]
                profiles.removeValue(forKey: service.rawValue)
                raw["meeting_app_profiles"] = profiles
            }
            apps[service.rawValue] = app?.path
            raw["meeting_apps"] = apps
        }
    }

    static func setChromeProfile(_ profile: URL?, for service: MeetingService,
                                 at path: URL = configURL) throws {
        if let profile, !isChromeProfileDirectory(profile.path) {
            throw MeetingLinkSettingsError.invalidProfile
        }
        try updateConfig(at: path) { raw in
            var profiles = raw["meeting_app_profiles"] as? [String: Any] ?? [:]
            profiles[service.rawValue] = profile?.standardizedFileURL.path
            raw["meeting_app_profiles"] = profiles
        }
    }

    func chromeProfilePath(for url: URL) -> String? {
        chromeProfiles[MeetingService.forURL(url).rawValue]
    }

    private static func updateConfig(at path: URL, update: (inout [String: Any]) -> Void) throws {
        var raw: [String: Any] = [:]
        if FileManager.default.fileExists(atPath: path.path) {
            let data = try Data(contentsOf: path)
            guard let existing = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw MeetingLinkSettingsError.invalidConfig
            }
            raw = existing
        }
        for key in ["meeting_apps", "meeting_app_profiles"] {
            if let existing = raw[key], !(existing is [String: Any]) {
                throw MeetingLinkSettingsError.invalidConfig
            }
        }
        update(&raw)
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

func isChromeProfileDirectory(_ path: String) -> Bool {
    guard path.hasPrefix("/"), !path.contains("\0") else { return false }
    let profile = URL(fileURLWithPath: path).standardizedFileURL
    guard profile.pathComponents.count > 2 else { return false }
    var directory: ObjCBool = false
    return FileManager.default.fileExists(atPath: profile.path, isDirectory: &directory)
        && directory.boolValue
}

enum MeetingLinkSettingsError: LocalizedError {
    case invalidConfig, invalidProfile

    var errorDescription: String? {
        switch self {
        case .invalidConfig:
            return "The config file is not a JSON object with valid meeting app settings. Fix it before saving."
        case .invalidProfile:
            return "Paste the full Profile Path from chrome://version in your chosen Chrome profile. That folder must exist on this Mac."
        }
    }
}
