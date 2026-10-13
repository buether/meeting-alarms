import AppKit
import UniformTypeIdentifiers

/// Holds a closure as an Objective-C action target.
final class ActionTarget: NSObject {
    private let handler: (Any?) -> Void
    init(_ handler: @escaping (Any?) -> Void) { self.handler = handler }
    @objc func fire(_ sender: Any?) { handler(sender) }
}

/// The "Meeting links" part of Settings: which app opens each kind of meeting
/// link, and for Chrome web apps, which Chrome profile.
final class MeetingLinkSection: NSObject {
    /// For sheets (the app chooser, the profile prompt).
    weak var window: NSWindow?
    /// Called after a choice is saved, or with a message when it is not.
    var onSaved: () -> Void = {}
    var onError: (String) -> Void = { _ in }

    private var popups: [NSPopUpButton] = []
    private var profilePopups: [NSPopUpButton] = []

    /// Rows for SettingsWindow's grid: a label and app menu per service, then a
    /// Chrome profile menu under it when the chosen app is a Chrome web app.
    func rows() -> [(label: String, control: NSView, visible: Bool)] {
        popups = []
        profilePopups = []
        let preferences = MeetingLinkPreferences.load()
        var rows: [(label: String, control: NSView, visible: Bool)] = []
        for (index, service) in MeetingService.allCases.enumerated() {
            let popup = NSPopUpButton()
            popup.tag = index
            popup.target = self
            popup.action = #selector(changeApp(_:))
            popup.setAccessibilityLabel("\(service.title) app")
            popup.addItem(withTitle: "macOS default")
            popup.lastItem?.tag = 0
            if let path = preferences.applications[service.rawValue] {
                let exists = FileManager.default.fileExists(atPath: path)
                let name = FileManager.default.displayName(atPath: path)
                popup.addItem(withTitle: exists ? name : "\(name) (unavailable)")
                popup.lastItem?.tag = 1
                popup.lastItem?.toolTip = path
                if exists {
                    let icon = NSWorkspace.shared.icon(forFile: path)
                    icon.size = NSSize(width: 16, height: 16)
                    popup.lastItem?.image = icon
                }
                popup.selectItem(at: 1)
            }
            popup.menu?.addItem(.separator())
            popup.addItem(withTitle: "Choose app…")
            popup.lastItem?.tag = 2
            popups.append(popup)
            rows.append((service.title, popup, true))

            let profile = NSPopUpButton()
            profile.font = .systemFont(ofSize: 12)
            profile.tag = index
            profile.target = self
            profile.action = #selector(changeProfile(_:))
            profile.setAccessibilityLabel("\(service.title) Chrome profile")
            profile.addItem(withTitle: "Chrome chooses profile")
            profile.lastItem?.tag = 0
            if let path = preferences.chromeProfiles[service.rawValue] {
                let name = URL(fileURLWithPath: path).lastPathComponent
                let suffix = isChromeProfileDirectory(path) ? "" : " (unavailable)"
                profile.addItem(withTitle: "Chrome profile: \(name)\(suffix)")
                profile.lastItem?.tag = 1
                profile.lastItem?.toolTip = path
                profile.selectItem(at: 1)
            }
            profile.menu?.addItem(.separator())
            profile.addItem(withTitle: "Choose profile…")
            profile.lastItem?.tag = 2
            profilePopups.append(profile)
            let isChrome = preferences.applications[service.rawValue].map {
                isChromeWebApp(at: URL(fileURLWithPath: $0))
            } ?? false
            rows.append(("", profile, isChrome))
        }
        return rows
    }

    @objc private func changeProfile(_ sender: NSPopUpButton) {
        let service = MeetingService.allCases[sender.tag]
        switch sender.selectedItem?.tag {
        case 0:
            saveProfile(nil, for: service)
        case 2:
            guard let window else { return }
            let alert = NSAlert()
            alert.messageText = "Choose a Chrome profile for \(service.title)"
            alert.informativeText = "In Chrome, switch to the profile you want and open chrome://version. Copy its Profile Path and paste it below. Install this web app in that profile and sign in to your meeting account there."
            alert.addButton(withTitle: "Save profile")
            alert.addButton(withTitle: "Cancel")
            let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 440, height: 26))
            field.placeholderString = "Paste Profile Path"
            field.stringValue = MeetingLinkPreferences.load().chromeProfiles[service.rawValue] ?? ""
            field.setAccessibilityLabel("Chrome Profile Path")
            alert.accessoryView = field
            alert.window.initialFirstResponder = field
            alert.beginSheetModal(for: window) { [weak self] response in
                guard response == .alertFirstButtonReturn else { self?.onSaved(); return }
                let path = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
                guard path.hasPrefix("/") else {
                    self?.onError(MeetingLinkSettingsError.invalidProfile.localizedDescription)
                    return
                }
                self?.saveProfile(URL(fileURLWithPath: path), for: service)
            }
        default: break
        }
    }

    private func saveProfile(_ profile: URL?, for service: MeetingService) {
        do {
            try MeetingLinkPreferences.setChromeProfile(profile, for: service)
            onSaved()
        } catch {
            onError(error.localizedDescription)
        }
    }

    @objc private func changeApp(_ sender: NSPopUpButton) {
        let service = MeetingService.allCases[sender.tag]
        switch sender.selectedItem?.tag {
        case 0:
            save(nil, for: service)
        case 2:
            guard let window else { return }
            let panel = NSOpenPanel()
            panel.title = "Choose an app for \(service.title)"
            panel.prompt = "Choose app"
            panel.allowedContentTypes = [.applicationBundle]
            panel.canChooseDirectories = false
            panel.allowsMultipleSelection = false
            panel.directoryURL = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Applications")
            panel.beginSheetModal(for: window) { [weak self] response in
                if response == .OK, let app = panel.url {
                    self?.save(app, for: service)
                } else {
                    self?.onSaved()
                }
            }
        default: break
        }
    }

    private func save(_ app: URL?, for service: MeetingService) {
        do {
            try MeetingLinkPreferences.setApplication(app, for: service)
            onSaved()
        } catch {
            onError(error.localizedDescription)
        }
    }
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
