import AppKit

private func chromeUserDataDirectory(info: [String: Any]) -> URL? {
    guard let appData = info["CrAppModeUserDataDir"] as? String, !appData.isEmpty else {
        return nil
    }
    return URL(fileURLWithPath: appData).deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent()
}

// Chrome web-app shims ignore HTTP URLs sent through Launch Services. This
// adapter is used only for a web app the user explicitly chose in Settings.
func chromeWebAppConfiguration(info: [String: Any], meetingURL: URL) -> NSWorkspace.OpenConfiguration? {
    guard let appID = info["CrAppModeShortcutID"] as? String, !appID.isEmpty else { return nil }
    var arguments = [
        "--app-id=\(appID)",
        "--app-launch-url-for-shortcuts-menu-item=\(meetingURL.absoluteString)",
    ]
    if let userData = chromeUserDataDirectory(info: info) {
        arguments.append("--user-data-dir=\(userData.path)")
    }
    if let profile = info["CrAppModeProfileDir"] as? String, !profile.isEmpty {
        arguments.append("--profile-directory=\(profile)")
    }
    let configuration = NSWorkspace.OpenConfiguration()
    configuration.arguments = arguments
    configuration.createsNewApplicationInstance = true
    return configuration
}

private func appInfo(at app: URL) -> [String: Any]? {
    guard let data = try? Data(contentsOf: app.appendingPathComponent("Contents/Info.plist")) else {
        return nil
    }
    return (try? PropertyListSerialization.propertyList(from: data, options: [], format: nil))
        as? [String: Any]
}

func chromeWebAppBrowserID(info: [String: Any]) -> String? {
    let browserID = info["CrBundleIdentifier"] as? String ?? "com.google.Chrome"
    guard let identifier = info["CFBundleIdentifier"] as? String,
          browserID == "com.google.Chrome" || browserID.hasPrefix("com.google.Chrome."),
          identifier.hasPrefix("\(browserID).app.") else { return nil }
    return browserID
}

private func openChosenMeetingApp(_ url: URL, in app: URL, completion: @escaping (Bool) -> Void) {
    let info = appInfo(at: app) ?? [:]
    let didOpen: (NSRunningApplication?, Error?) -> Void = { runningApp, error in
        DispatchQueue.main.async { completion(runningApp != nil && error == nil) }
    }
    if let browserID = chromeWebAppBrowserID(info: info) {
        guard let configuration = chromeWebAppConfiguration(info: info, meetingURL: url),
              let chrome = NSWorkspace.shared.urlForApplication(withBundleIdentifier: browserID)
        else {
            completion(false)
            return
        }
        NSWorkspace.shared.openApplication(at: chrome, configuration: configuration,
                                           completionHandler: didOpen)
    } else {
        let configuration = NSWorkspace.OpenConfiguration()
        NSWorkspace.shared.open([url], withApplicationAt: app, configuration: configuration,
                                completionHandler: didOpen)
    }
}

struct MeetingLinkOpener {
    var preferences = MeetingLinkPreferences.load()
    var openDefault: (URL) -> Void = { _ = NSWorkspace.shared.open($0) }
    var openInApplication: (URL, URL, @escaping (Bool) -> Void) -> Void = {
        openChosenMeetingApp($0, in: $1, completion: $2)
    }

    /// Completes after handing off the URL, so the alarm can exit without
    /// losing the default-handler fallback when an asynchronous app launch fails.
    func open(_ url: URL, completion: @escaping () -> Void) {
        guard let app = preferences.application(for: url) else {
            openDefault(url)
            completion()
            return
        }
        openInApplication(url, app) { opened in
            if !opened { openDefault(url) }
            completion()
        }
    }
}
