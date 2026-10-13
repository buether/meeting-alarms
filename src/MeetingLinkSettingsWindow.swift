import AppKit
import UniformTypeIdentifiers

final class MeetingLinkSettingsWindow: NSObject, NSWindowDelegate {
    private var window: NSWindow?
    private var heading: NSTextField?
    private var detail: NSTextField?
    private var labels: [NSTextField] = []
    private var popups: [NSPopUpButton] = []
    private var profilePopups: [NSPopUpButton] = []
    private var note: NSTextField?
    private let level: NSWindow.Level
    private let onClose: () -> Void

    init(level: NSWindow.Level = .normal, onClose: @escaping () -> Void = {}) {
        self.level = level
        self.onClose = onClose
    }

    func show() {
        if window == nil { buildWindow() }
        refreshChoices()
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func close() { window?.close() }
    func windowWillClose(_ notification: Notification) { onClose() }

    private func buildWindow() {
        let bounds = NSRect(x: 0, y: 0, width: 560, height: 560)
        let window = NSWindow(contentRect: bounds, styleMask: [.titled, .closable],
                              backing: .buffered, defer: false)
        window.title = "Meeting Link Settings"
        window.level = level
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        window.isReleasedWhenClosed = false
        window.delegate = self
        let content = NSView(frame: bounds)

        let heading = NSTextField(labelWithString: "Open meeting links with")
        heading.font = .systemFont(ofSize: 20, weight: .semibold)
        heading.frame = NSRect(x: 24, y: 504, width: 512, height: 28)
        content.addSubview(heading)
        self.heading = heading
        let detail = NSTextField(wrappingLabelWithString:
            "Use your Mac’s default, or choose an app just for Meeting Alarm.")
        detail.textColor = .secondaryLabelColor
        detail.frame = NSRect(x: 24, y: 463, width: 512, height: 34)
        content.addSubview(detail)
        self.detail = detail

        for (index, service) in MeetingService.allCases.enumerated() {
            let y = 419 - CGFloat(index) * 76
            let label = NSTextField(labelWithString: service.title)
            label.frame = NSRect(x: 24, y: y + 6, width: 154, height: 20)
            content.addSubview(label)
            labels.append(label)
            let popup = NSPopUpButton(frame: NSRect(x: 184, y: y, width: 352, height: 32))
            popup.tag = index
            popup.target = self
            popup.action = #selector(changeApp(_:))
            popup.setAccessibilityLabel("\(service.title) app")
            content.addSubview(popup)
            popups.append(popup)

            let profile = NSPopUpButton(frame: NSRect(x: 184, y: y - 28, width: 352, height: 26))
            profile.font = .systemFont(ofSize: 12)
            profile.tag = index
            profile.target = self
            profile.action = #selector(changeProfile(_:))
            profile.setAccessibilityLabel("\(service.title) Chrome profile")
            content.addSubview(profile)
            profilePopups.append(profile)
        }

        let note = NSTextField(wrappingLabelWithString: "")
        note.font = .systemFont(ofSize: 12)
        note.frame = NSRect(x: 24, y: 20, width: 512, height: 48)
        content.addSubview(note)
        self.note = note
        window.contentView = content
        window.center()
        self.window = window
    }

    private func refreshChoices() {
        let preferences = MeetingLinkPreferences.load()
        for (index, popup) in popups.enumerated() {
            let service = MeetingService.allCases[index]
            popup.removeAllItems()
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

            let profile = profilePopups[index]
            profile.isHidden = preferences.applications[service.rawValue].map {
                !isChromeWebApp(at: URL(fileURLWithPath: $0))
            } ?? true
            profile.removeAllItems()
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
        }
        let height = 410 + CGFloat(profilePopups.filter { !$0.isHidden }.count) * 28
        window?.setContentSize(NSSize(width: 560, height: height))
        heading?.frame.origin.y = height - 56
        detail?.frame.origin.y = height - 97
        var y = height - 141
        for index in popups.indices {
            labels[index].frame.origin.y = y + 6
            popups[index].frame.origin.y = y
            profilePopups[index].frame.origin.y = y - 28
            y -= profilePopups[index].isHidden ? 48 : 76
        }
        note?.stringValue = "Changes save immediately. If a chosen app is unavailable or fails to open, your Mac’s default handles the link."
        note?.textColor = .secondaryLabelColor
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
                if response == .alertFirstButtonReturn {
                    let path = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard path.hasPrefix("/") else {
                        self?.showSaveError(MeetingLinkSettingsError.invalidProfile)
                        return
                    }
                    self?.saveProfile(URL(fileURLWithPath: path), for: service)
                } else {
                    self?.refreshChoices()
                }
            }
        default: break
        }
    }

    private func saveProfile(_ profile: URL?, for service: MeetingService) {
        do {
            try MeetingLinkPreferences.setChromeProfile(profile, for: service)
            refreshChoices()
        } catch {
            showSaveError(error)
        }
    }

    private func showSaveError(_ error: Error) {
        refreshChoices()
        note?.stringValue = "Couldn’t save this choice: \(error.localizedDescription)"
        note?.textColor = .systemRed
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
                    self?.refreshChoices()
                }
            }
        default: break
        }
    }

    private func save(_ app: URL?, for service: MeetingService) {
        do {
            try MeetingLinkPreferences.setApplication(app, for: service)
            refreshChoices()
        } catch {
            showSaveError(error)
        }
    }
}
