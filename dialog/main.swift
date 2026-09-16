import AppKit

// usage: meeting-alarm-dialog <headline> <detail> <timeout-seconds> [meeting-url]
// Exits 0 when Dismiss or Join is clicked, 2 when the timeout elapses first.
let arguments = CommandLine.arguments
let headline = arguments.count > 1 ? arguments[1] : "Meeting starting"
let detail = arguments.count > 2 ? arguments[2] : ""
let timeout = arguments.count > 3 ? (Double(arguments[3]) ?? 0) : 0
let meetingURL = arguments.count > 4 ? arguments[4] : ""

final class AlarmWindow: NSObject, NSApplicationDelegate {
    private var window: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let bounds = NSRect(x: 0, y: 0, width: 560, height: 260)
        let window = NSWindow(contentRect: bounds, styleMask: [.titled], backing: .buffered, defer: false)
        window.title = "Meeting Alarm"
        window.level = .screenSaver
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        window.isReleasedWhenClosed = false
        window.backgroundColor = NSColor(calibratedRed: 0.12, green: 0.14, blue: 0.20, alpha: 1)

        let content = NSView(frame: bounds)

        let headlineField = NSTextField(wrappingLabelWithString: headline)
        headlineField.font = NSFont.systemFont(ofSize: 40, weight: .bold)
        headlineField.textColor = .white
        headlineField.alignment = .center
        headlineField.frame = NSRect(x: 20, y: 150, width: 520, height: 80)
        content.addSubview(headlineField)

        let detailField = NSTextField(wrappingLabelWithString: detail)
        detailField.font = NSFont.systemFont(ofSize: 18)
        detailField.textColor = NSColor(calibratedWhite: 0.85, alpha: 1)
        detailField.alignment = .center
        detailField.frame = NSRect(x: 20, y: 95, width: 520, height: 44)
        content.addSubview(detailField)

        let dismissButton = NSButton(title: "Dismiss", target: self, action: #selector(dismiss))
        dismissButton.bezelStyle = .rounded
        dismissButton.controlSize = .large
        if meetingURL.isEmpty {
            dismissButton.keyEquivalent = "\r"
            dismissButton.frame = NSRect(x: 210, y: 25, width: 140, height: 44)
        } else {
            let joinButton = NSButton(title: "Join", target: self, action: #selector(join))
            joinButton.bezelStyle = .rounded
            joinButton.controlSize = .large
            joinButton.keyEquivalent = "\r"
            joinButton.frame = NSRect(x: 130, y: 25, width: 140, height: 44)
            content.addSubview(joinButton)
            dismissButton.frame = NSRect(x: 290, y: 25, width: 140, height: 44)
        }
        content.addSubview(dismissButton)

        window.contentView = content
        window.center()
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()
        NSApp.activate(ignoringOtherApps: true)
        self.window = window

        if timeout > 0 {
            DispatchQueue.main.asyncAfter(deadline: .now() + timeout) { exit(2) }
        }
    }

    @objc private func dismiss() {
        exit(0)
    }

    @objc private func join() {
        if let url = URL(string: meetingURL) {
            NSWorkspace.shared.open(url)
        }
        exit(0)
    }
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let delegate = AlarmWindow()
app.delegate = delegate
app.run()
