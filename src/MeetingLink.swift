import AppKit

func chromeMeetArguments(info: [String: Any], meetingURL: URL) -> [String]? {
    guard let appID = info["CrAppModeShortcutID"] as? String, !appID.isEmpty else { return nil }
    var arguments = [
        "--app-id=\(appID)",
        "--app-launch-url-for-shortcuts-menu-item=\(meetingURL.absoluteString)",
    ]
    if let appData = info["CrAppModeUserDataDir"] as? String, !appData.isEmpty {
        let userData = URL(fileURLWithPath: appData).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        arguments.append("--user-data-dir=\(userData.path)")
    }
    if let profile = info["CrAppModeProfileDir"] as? String, !profile.isEmpty {
        arguments.append("--profile-directory=\(profile)")
    }
    return arguments
}

private func appInfo(at app: URL) -> [String: Any]? {
    guard let data = try? Data(contentsOf: app.appendingPathComponent("Contents/Info.plist")) else {
        return nil
    }
    return (try? PropertyListSerialization.propertyList(from: data, options: [], format: nil))
        as? [String: Any]
}

private func isGoogleMeetURL(_ url: URL) -> Bool {
    url.scheme?.lowercased() == "https"
        && url.host?.lowercased() == "meet.google.com"
        && (url.port == nil || url.port == 443)
}

/// Finds saved Chrome or Safari Meet apps by their URL metadata, including
/// renamed apps. Chrome takes priority; within a browser, directory order wins.
func findMeetWebApp(in directories: [URL]) -> URL? {
    var safariApp: URL?
    for directory in directories {
        guard let entries = FileManager.default.enumerator(
            at: directory, includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else { continue }

        var apps: [URL] = []
        for case let entry as URL in entries {
            if entry.pathExtension.lowercased() == "app" {
                entries.skipDescendants()
                apps.append(entry)
            }
        }
        for app in apps.sorted(by: { $0.path < $1.path }) {
            guard let info = appInfo(at: app),
                  let identifier = info["CFBundleIdentifier"] as? String else { continue }

            if identifier.hasPrefix("com.google.Chrome.app."),
               let appID = info["CrAppModeShortcutID"] as? String, !appID.isEmpty,
               let shortcut = info["CrAppModeShortcutURL"] as? String,
               let url = URL(string: shortcut), isGoogleMeetURL(url) {
                return app
            }
            if safariApp == nil, identifier.hasPrefix("com.apple.Safari.WebApp."),
               let manifest = info["WKManifestURL"] as? String,
               let url = URL(string: manifest), isGoogleMeetURL(url) {
                safariApp = app
            }
        }
    }
    return safariApp
}

/// Chrome's app shim ignores HTTP URLs passed through Launch Services. Launch
/// Chrome with an app ID and URL override; a new instance delivers the flags
/// even when Chrome is already running. Safari accepts the URL directly.
private func openSavedMeetApp(_ url: URL, in app: URL, completion: @escaping (Bool) -> Void) {
    guard let info = appInfo(at: app), let identifier = info["CFBundleIdentifier"] as? String else {
        completion(false)
        return
    }
    let configuration = NSWorkspace.OpenConfiguration()
    let didOpen: (NSRunningApplication?, Error?) -> Void = { runningApp, error in
        DispatchQueue.main.async { completion(runningApp != nil && error == nil) }
    }
    if identifier.hasPrefix("com.google.Chrome.app.") {
        guard let arguments = chromeMeetArguments(info: info, meetingURL: url),
              let chrome = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.google.Chrome")
        else {
            completion(false)
            return
        }
        configuration.arguments = arguments
        configuration.createsNewApplicationInstance = true
        NSWorkspace.shared.openApplication(at: chrome, configuration: configuration,
                                           completionHandler: didOpen)
    } else {
        NSWorkspace.shared.open([url], withApplicationAt: app, configuration: configuration,
                                completionHandler: didOpen)
    }
}

struct MeetingLinkOpener {
    var applicationDirectories: [URL] = [
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications"),
        URL(fileURLWithPath: "/Applications"),
    ]
    var openDefault: (URL) -> Void = { _ = NSWorkspace.shared.open($0) }
    var openInApplication: (URL, URL, @escaping (Bool) -> Void) -> Void = {
        openSavedMeetApp($0, in: $1, completion: $2)
    }

    /// Completes after handing off the URL, so the alarm can exit without
    /// losing the browser fallback when an asynchronous app launch fails.
    func open(_ url: URL, completion: @escaping () -> Void) {
        guard isGoogleMeetURL(url), let app = findMeetWebApp(in: applicationDirectories) else {
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
