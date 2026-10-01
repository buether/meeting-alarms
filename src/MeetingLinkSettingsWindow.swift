import AppKit
import UniformTypeIdentifiers

final class MeetingLinkSettingsWindow: NSObject, NSWindowDelegate {
    private var window: NSWindow?
    private var popups: [NSPopUpButton] = []
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
        let bounds = NSRect(x: 0, y: 0, width: 560, height: 410)
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
        heading.frame = NSRect(x: 24, y: 354, width: 512, height: 28)
        content.addSubview(heading)
        let detail = NSTextField(wrappingLabelWithString:
            "Use your Mac’s default, or choose an app just for Meeting Alarm.")
        detail.textColor = .secondaryLabelColor
        detail.frame = NSRect(x: 24, y: 313, width: 512, height: 34)
        content.addSubview(detail)

        for (index, service) in MeetingService.allCases.enumerated() {
            let y = 269 - CGFloat(index) * 48
            let label = NSTextField(labelWithString: service.title)
            label.frame = NSRect(x: 24, y: y + 6, width: 154, height: 20)
            content.addSubview(label)
            let popup = NSPopUpButton(frame: NSRect(x: 184, y: y, width: 352, height: 32))
            popup.tag = index
            popup.target = self
            popup.action = #selector(changeApp(_:))
            popup.setAccessibilityLabel("\(service.title) app")
            content.addSubview(popup)
            popups.append(popup)
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
        }
        note?.stringValue = "Changes save immediately. If a chosen app is unavailable or fails to open, your Mac’s default handles the link."
        note?.textColor = .secondaryLabelColor
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
            refreshChoices()
            note?.stringValue = "Couldn’t save this choice: \(error.localizedDescription)"
            note?.textColor = .systemRed
        }
    }
}
