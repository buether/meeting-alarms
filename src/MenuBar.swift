import AppKit

final class MeetingAlarmMenuBar: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var statusItem: NSStatusItem?
    private let healthItem = NSMenuItem(title: "Checking calendar…", action: nil, keyEquivalent: "")
    private var timer: Timer?
    private let settings = MeetingLinkSettingsWindow()

    func applicationDidFinishLaunching(_ notification: Notification) {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        let menu = NSMenu()
        menu.delegate = self
        menu.addItem(healthItem)
        menu.addItem(.separator())
        for (title, action) in [("Settings…", #selector(showSettings)),
                                ("Refresh status", #selector(refreshStatus))] {
            let entry = NSMenuItem(title: title, action: action, keyEquivalent: "")
            entry.target = self
            menu.addItem(entry)
        }
        item.menu = menu
        statusItem = item
        refreshStatus()
        let timer = Timer(timeInterval: 30, target: self, selector: #selector(refreshStatus),
                          userInfo: nil, repeats: true)
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        NSWorkspace.shared.notificationCenter.addObserver(
            self, selector: #selector(didWake(_:)), name: NSWorkspace.didWakeNotification,
            object: nil)
    }

    func menuWillOpen(_ menu: NSMenu) { refreshStatus() }

    @objc private func showSettings() { settings.show() }
    @objc private func didWake(_ notification: Notification) { refreshStatus() }

    @objc private func refreshStatus() {
        let state = State.load()
        let loaded = launchctl(["print", "gui/\(getuid())/\(Paths.label)"]).code == 0
        let health = pollerHealth(loaded: loaded, lastOk: state.lastOk,
                                  failingSince: state.failingSince, lastError: state.lastError,
                                  now: Date().timeIntervalSince1970,
                                  pollSeconds: Config.load().pollSeconds)
        let title = health.ok ? "Meeting Alarm is running" : "Meeting Alarm needs attention"
        let image = NSImage(systemSymbolName: health.ok ? "bell.fill" : "bell.badge.fill",
                            accessibilityDescription: title)
        image?.isTemplate = true
        image?.size = NSSize(width: 16, height: 16)
        statusItem?.button?.image = image
        statusItem?.button?.title = image == nil ? (health.ok ? "●" : "!") : ""
        statusItem?.button?.toolTip = "\(title)\n\(health.line)"
        statusItem?.button?.setAccessibilityLabel(title)
        healthItem.title = health.ok ? "Calendar checks are up to date" : "\(health.line.prefix(100))"
        healthItem.toolTip = health.line
    }

    func applicationWillTerminate(_ notification: Notification) {
        timer?.invalidate()
        NSWorkspace.shared.notificationCenter.removeObserver(self)
        if let statusItem { NSStatusBar.system.removeStatusItem(statusItem) }
    }
}
