import AppKit

enum AlarmOutcome: String {
    case dismissed
    case joined
    case gaveUp = "gave_up"
}

/// The alarm window. Used to be a separate binary the poller spawned and read an
/// exit code from; now it just calls back.
final class AlarmWindow {
    private var window: NSWindow?
    private let onFinish: (AlarmOutcome) -> Void
    private let meetingURL: String

    init(meetingURL: String, onFinish: @escaping (AlarmOutcome) -> Void) {
        self.meetingURL = meetingURL
        self.onFinish = onFinish
    }

    func show(headline: String, detail: String) {
        let bounds = NSRect(x: 0, y: 0, width: 560, height: 260)
        let window = NSWindow(contentRect: bounds, styleMask: [.titled],
                              backing: .buffered, defer: false)
        window.title = "Meeting Alarm"
        // Rings over full-screen apps, on whatever Space is in front.
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
    }

    func close() {
        window?.orderOut(nil)
        window = nil
    }

    @objc private func dismiss() { onFinish(.dismissed) }

    @objc private func join() {
        if let url = URL(string: meetingURL) {
            NSWorkspace.shared.open(url)
        }
        onFinish(.joined)
    }
}

/// Plain alert with no sound, for calendar failures and the watchdog.
func showNotice(message: String, title: String, seconds: Double) {
    let alert = NSAlert()
    alert.messageText = title
    alert.informativeText = message
    alert.alertStyle = .critical
    alert.addButton(withTitle: "OK")
    if seconds > 0 {
        // runModal spins the run loop in .modalPanel, which a plain main-queue
        // dispatch does not reach.
        let timer = Timer(timeInterval: seconds, repeats: false) { _ in NSApp.abortModal() }
        RunLoop.current.add(timer, forMode: .modalPanel)
        RunLoop.current.add(timer, forMode: .common)
    }
    NSApp.activate(ignoringOtherApps: true)
    alert.window.level = .floating
    _ = alert.runModal()
}
