import AppKit
import UniformTypeIdentifiers

/// Every setting in config.json, editable, one window. Each change is written
/// straight to the file and the window is redrawn from it, so what is shown is
/// always what is saved. Each row names its config key so the window and the
/// documentation line up.
final class SettingsWindow: NSObject, NSWindowDelegate {
    private var window: NSWindow?
    private var scroll: NSScrollView?
    private let level: NSWindow.Level
    private let onClose: () -> Void
    private var targets: [ActionTarget] = []
    private let links = MeetingLinkSection()
    private var player: NSSound?
    private var message: (text: String, error: Bool) = ("", false)

    init(level: NSWindow.Level = .normal, onClose: @escaping () -> Void = {}) {
        self.level = level
        self.onClose = onClose
        super.init()
        links.onSaved = { [weak self] in self?.saved() }
        links.onError = { [weak self] in self?.failed($0) }
    }

    func show() {
        if window == nil { buildWindow() }
        render()
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func close() { window?.close() }

    func windowWillClose(_ notification: Notification) {
        player?.stop()
        onClose()
    }

    /// Draws the whole settings page into a PNG, for checking the layout
    /// without a screen.
    func snapshot(to url: URL) throws {
        if window == nil { buildWindow() }
        // Light, on an opaque ground: in dark mode the labels are white, and a
        // transparent PNG of white text reads as blank.
        window?.appearance = NSAppearance(named: .aqua)
        render()
        guard let document = scroll?.documentView else { return }
        document.layoutSubtreeIfNeeded()
        guard let bitmap = document.bitmapImageRepForCachingDisplay(in: document.bounds) else { return }
        document.cacheDisplay(in: document.bounds, to: bitmap)
        let image = NSImage(size: document.bounds.size)
        image.lockFocus()
        NSColor.windowBackgroundColor.setFill()
        document.bounds.fill()
        bitmap.draw(in: document.bounds)
        image.unlockFocus()
        guard let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff) else { return }
        try rep.representation(using: .png, properties: [:])?.write(to: url)
    }

    // MARK: - Window

    private func buildWindow() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 680, height: 760),
                              styleMask: [.titled, .closable, .resizable, .miniaturizable],
                              backing: .buffered, defer: false)
        window.title = "Meeting Alarm Settings"
        window.level = level
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 680, height: 360)
        window.delegate = self
        let scroll = NSScrollView(frame: window.contentLayoutRect)
        scroll.hasVerticalScroller = true
        scroll.autoresizingMask = [.width, .height]
        scroll.drawsBackground = false
        window.contentView = scroll
        window.center()
        self.window = window
        self.scroll = scroll
        links.window = window
    }

    private func render() {
        guard let scroll else { return }
        let origin = scroll.contentView.bounds.origin
        targets = []
        let cfg = Config.load()

        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 22
        stack.edgeInsets = NSEdgeInsets(top: 24, left: 28, bottom: 28, right: 28)
        stack.translatesAutoresizingMaskIntoConstraints = false

        let intro = label("Changes save as you make them. Each setting shows its key in config.json.",
                          size: 12, color: .secondaryLabelColor)
        stack.addArrangedSubview(intro)
        if !message.text.isEmpty {
            stack.addArrangedSubview(label(message.text, size: 12,
                                           color: message.error ? .systemRed : .systemGreen))
        }
        for section in [alarmSection(cfg), soundSection(cfg), calendarSection(cfg),
                        linkSection(), checkingSection(cfg), fileSection()] {
            stack.addArrangedSubview(section)
        }

        let flipped = FlippedView()
        flipped.translatesAutoresizingMaskIntoConstraints = false
        flipped.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: flipped.topAnchor),
            stack.leadingAnchor.constraint(equalTo: flipped.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: flipped.trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: flipped.bottomAnchor),
            flipped.widthAnchor.constraint(equalToConstant: 664),
        ])
        scroll.documentView = flipped
        flipped.layoutSubtreeIfNeeded()
        scroll.contentView.scroll(to: origin)
        scroll.reflectScrolledClipView(scroll.contentView)
    }

    // MARK: - Sections

    private func alarmSection(_ cfg: Config) -> NSView {
        section("Alarm", rows: [
            row("Message", key: "message",
                help: "The headline in the alarm window, and what is spoken.",
                textField(cfg.message, width: 300) { [weak self] in self?.save("message", $0) }),
            row("Ring this early", key: "lead_seconds",
                help: "Seconds before the meeting starts.",
                numberField(cfg.leadSeconds, unit: "seconds") { [weak self] in self?.save("lead_seconds", $0) }),
            row("Give up after", key: "max_alarm_seconds",
                help: "Seconds after the start to stop ringing. 0 rings until you dismiss it.",
                numberField(cfg.maxAlarmSeconds, unit: "seconds") { [weak self] in self?.save("max_alarm_seconds", $0) }),
            row("Speak the message", key: "speak",
                help: "Say the message out loud before the sound starts.",
                checkbox("Speak", on: cfg.speak) { [weak self] in self?.save("speak", $0) }),
        ])
    }

    private func soundSection(_ cfg: Config) -> NSView {
        let slider = NSSlider(value: Double(cfg.volume), minValue: 0, maxValue: 100,
                              target: nil, action: nil)
        slider.isContinuous = false
        slider.widthAnchor.constraint(equalToConstant: 220).isActive = true
        let value = label("\(cfg.volume)%", size: 13, color: .labelColor)
        bind(slider) { [weak self] _ in self?.save("volume", Int(slider.doubleValue.rounded())) }
        let volume = hstack([slider, value])

        var rows = [
            row("Sound", key: "sound", help: "Looped until the alarm is dismissed.",
                soundPicker(current: cfg.sound, key: "sound")),
            row("Fallback sound", key: "fallback_sound",
                help: "Used when the sound file is missing. With neither, the alarm still speaks and shows its window.",
                soundPicker(current: cfg.fallbackSound, key: "fallback_sound")),
            row("Volume while ringing", key: "volume",
                help: "Output volume during the alarm. Yours is put back afterwards.", volume),
            row("Ring through mute", key: "break_mute",
                help: "Off leaves a muted Mac muted: the window still appears, silently.",
                checkbox("Unmute to ring", on: cfg.breakMute) { [weak self] in self?.save("break_mute", $0) }),
        ]
        if cfg.resolvedSound == nil {
            rows.insert(row("", key: nil, help: nil,
                            label("Neither sound file is on this Mac; the alarm will not loop a sound.",
                                  size: 12, color: .systemRed)), at: 0)
        }
        return section("Sound", rows: rows)
    }

    private func calendarSection(_ cfg: Config) -> NSView {
        guard let calendars = try? CalendarStore.calendars() else {
            return section("Calendars", rows: [row("", key: nil, help: nil,
                label("Calendar access has not been granted, so calendars cannot be listed. "
                      + "Turn on Meeting Alarm under System Settings > Privacy & Security > Calendars.",
                      size: 12, color: .systemRed))])
        }
        let plan = planCalendars(calendars, include: cfg.includeCalendars)
        let ringable = plan.rows.filter { $0.watch != .neverRings }
        let titles = ringable.map(\.calendar.title)
        let watchAll = cfg.includeCalendars.isEmpty

        var boxes: [NSView] = [
            checkbox("Watch every calendar", on: watchAll) { [weak self] on in
                self?.save("include_calendars", includeAfterWatchAll(on, allTitles: titles))
            },
        ]
        for (calendar, watch) in ringable {
            let box = checkbox("\(calendar.title)  —  \(calendar.source)", on: watch == .watched) { [weak self] on in
                guard let list = includeAfterToggle(cfg.includeCalendars, title: calendar.title, on: on) else {
                    self?.failed("At least one calendar has to stay ticked. To watch them all, tick “Watch every calendar”.")
                    return
                }
                self?.save("include_calendars", list)
            }
            (box as? NSButton)?.isEnabled = !watchAll
            boxes.append(indent(box))
        }
        for miss in plan.unmatched {
            let box = checkbox("\(miss.name)  —  no calendar has this name, nothing from it rings",
                               on: true) { [weak self] on in
                if !on, let list = includeAfterToggle(cfg.includeCalendars, title: miss.name, on: false) {
                    self?.save("include_calendars", list)
                } else if !on {
                    self?.save("include_calendars", [String]())
                }
            }
            (box as? NSButton)?.contentTintColor = .systemRed
            boxes.append(indent(box))
        }
        let never = plan.rows.filter { $0.watch == .neverRings }.map(\.calendar.title)
        if !never.isEmpty {
            boxes.append(indent(label("Never ring (birthdays and subscriptions have no attendees): "
                                      + never.joined(separator: ", "), size: 11, color: .secondaryLabelColor)))
        }

        // Accounts: what is here, how recently it changed, and anything gone.
        let state = State.load()
        let now = Date()
        var known = state.accounts
        if let live = try? CalendarStore.liveAccounts() {
            known = updateAccounts(known, live: live, now: now.timeIntervalSince1970,
                                   activity: try? CalendarStore.accountActivity(now: now))
        }
        let t = now.timeIntervalSince1970
        var accountViews: [NSView] = known.values
            .filter { t - $0.lastSeen <= accountGoneAfterSeconds }
            .sorted { ($0.local ? 1 : 0, $0.title) < ($1.local ? 1 : 0, $1.title) }
            .map { record in
                let activity = accountActivityLine(record, now: t)
                return label("\(record.title) (\(record.calendars.joined(separator: ", "))) — \(activity.text)",
                             size: 12, color: activity.quiet ? .systemOrange : .labelColor)
            }
        let problems = accountProblems(known, now: t, expectedSource: cfg.expectedSource)
        for problem in problems {
            accountViews.append(label(problem.line, size: 12, color: .systemRed))
        }
        if problems.contains(where: { if case .gone = $0 { return true } else { return false } }) {
            accountViews.append(button("Forget gone accounts") { [weak self] in
                _ = accountsCommand(forget: true)
                self?.saved()
            })
        }

        let required = NSPopUpButton()
        required.addItem(withTitle: "None")
        let accountTitles = Array(Set(known.values.filter { !$0.local }.map(\.title))).sorted()
        for title in accountTitles { required.addItem(withTitle: title) }
        if let expected = cfg.expectedSource {
            if !accountTitles.contains(expected) { required.addItem(withTitle: "\(expected) (not here)") }
            required.selectItem(withTitle: accountTitles.contains(expected) ? expected : "\(expected) (not here)")
        }
        bind(required) { [weak self] _ in
            let title = required.indexOfSelectedItem == 0 ? nil : required.titleOfSelectedItem
            if title?.hasSuffix(" (not here)") == true { return }
            self?.save("expected_source", title)
        }

        return section("Calendars and accounts", rows: [
            row("Watch", key: "include_calendars",
                help: "Only events in ticked calendars ring. Check the result with meeting-alarm status.",
                vstack(boxes)),
            row("Accounts", key: nil,
                help: "An account signed out or switched off for Calendars stops getting invites. "
                    + "A gone account is shown here, in status, and in the menu bar.",
                vstack(accountViews.isEmpty ? [label("None seen yet.", size: 12, color: .secondaryLabelColor)]
                                            : accountViews)),
            row("Required account", key: "expected_source",
                help: "Report this account as missing even if it was never seen. Usually unnecessary.",
                required),
        ])
    }

    private func linkSection() -> NSView {
        let rows = links.rows().map { item in
            row(item.label, key: item.label.isEmpty ? nil : "meeting_apps", help: nil, item.control,
                hidden: !item.visible)
        }
        return section("Meeting links", rows: rows,
                       note: "Which app the Join button opens, per kind of link (meeting_apps, and "
                           + "meeting_app_profiles for Chrome web apps). An app that is missing or fails to "
                           + "open falls back to your Mac’s default.")
    }

    private func checkingSection(_ cfg: Config) -> NSView {
        let interval = NSPopUpButton()
        let current = max(1, Int((cfg.pollSeconds / 60).rounded()))
        for minutes in pollIntervalChoices(current: cfg.pollSeconds) {
            interval.addItem(withTitle: minutes == 1 ? "Every minute" : "Every \(minutes) minutes")
            interval.lastItem?.tag = minutes
        }
        interval.selectItem(withTag: current)
        bind(interval) { [weak self] _ in
            guard let minutes = interval.selectedItem?.tag else { return }
            self?.save("poll_seconds", minutes * 60, then: { reloadPollerAgent() })
        }
        return section("Checking and reporting", rows: [
            row("Check the calendar", key: "poll_seconds",
                help: "How often the calendar is read. Every minute is what makes a 15-second warning possible.",
                interval),
            row("Report failures after", key: "failure_notice_after_seconds",
                help: "How long checks must fail before a dialog says so.",
                numberField(cfg.failureNoticeAfterSeconds, unit: "seconds") { [weak self] in
                    self?.save("failure_notice_after_seconds", $0) }),
            row("Repeat that report every", key: "failure_notice_every_seconds",
                help: "Shortest gap between those dialogs.",
                numberField(cfg.failureNoticeEverySeconds, unit: "seconds") { [weak self] in
                    self?.save("failure_notice_every_seconds", $0) }),
            row("Remember rung meetings", key: "fired_retention_seconds",
                help: "How long a meeting is remembered as already rung, so it does not ring twice.",
                numberField(cfg.firedRetentionSeconds, unit: "seconds") { [weak self] in
                    self?.save("fired_retention_seconds", $0) }),
        ])
    }

    private func fileSection() -> NSView {
        let path = ConfigFile.url
        let shown = path.path.replacingOccurrences(
            of: FileManager.default.homeDirectoryForCurrentUser.path, with: "~")
        let exists = FileManager.default.fileExists(atPath: path.path)
        var views: [NSView] = [label(exists ? shown : "\(shown) (created on first change)",
                                     size: 12, color: .secondaryLabelColor)]
        if exists {
            views.append(button("Show in Finder") {
                NSWorkspace.shared.activateFileViewerSelecting([path])
            })
        }
        return section("Config file", rows: [row("", key: nil, help: nil, hstack(views))])
    }

    // MARK: - Saving

    private func save(_ key: String, _ value: Any?, then after: (() -> Void)? = nil) {
        do {
            try ConfigFile.set(key, value)
            after?()
            saved()
        } catch {
            failed("Couldn’t save \(key): \(error.localizedDescription)")
        }
    }

    private func saved() {
        message = ("Saved.", false)
        render()
    }

    private func failed(_ text: String) {
        message = (text, true)
        render()
    }

    // MARK: - Controls

    private func bind(_ control: NSControl, _ handler: @escaping (Any?) -> Void) {
        let target = ActionTarget(handler)
        targets.append(target)
        control.target = target
        control.action = #selector(ActionTarget.fire(_:))
    }

    private func label(_ text: String, size: CGFloat, color: NSColor, bold: Bool = false) -> NSTextField {
        let field = NSTextField(wrappingLabelWithString: text)
        field.font = bold ? .systemFont(ofSize: size, weight: .semibold) : .systemFont(ofSize: size)
        field.textColor = color
        field.preferredMaxLayoutWidth = 400
        return field
    }

    private func textField(_ value: String, width: CGFloat, onCommit: @escaping (String) -> Void) -> NSView {
        let field = NSTextField(string: value)
        field.widthAnchor.constraint(equalToConstant: width).isActive = true
        (field.cell as? NSTextFieldCell)?.sendsActionOnEndEditing = true
        bind(field) { _ in
            if field.stringValue != value { onCommit(field.stringValue) }
        }
        return field
    }

    private func numberField(_ value: Double, unit: String, onCommit: @escaping (Int) -> Void) -> NSView {
        let field = NSTextField(string: String(Int(value)))
        field.alignment = .right
        field.widthAnchor.constraint(equalToConstant: 80).isActive = true
        (field.cell as? NSTextFieldCell)?.sendsActionOnEndEditing = true
        bind(field) { [weak self] _ in
            let text = field.stringValue.trimmingCharacters(in: .whitespaces)
            guard text != String(Int(value)) else { return }
            guard let number = Int(text), number >= 0 else {
                self?.failed("“\(text)” is not a whole number of zero or more.")
                return
            }
            onCommit(number)
        }
        return hstack([field, label(unit, size: 13, color: .secondaryLabelColor)])
    }

    private func checkbox(_ title: String, on: Bool, onToggle: @escaping (Bool) -> Void) -> NSView {
        let box = NSButton(checkboxWithTitle: title, target: nil, action: nil)
        box.state = on ? .on : .off
        bind(box) { _ in onToggle(box.state == .on) }
        return box
    }

    private func button(_ title: String, action: @escaping () -> Void) -> NSView {
        let button = NSButton(title: title, target: nil, action: nil)
        button.bezelStyle = .rounded
        bind(button) { _ in action() }
        return button
    }

    /// A menu of Apple's ringtones and system sounds, any other file already
    /// chosen, "Choose file…", and a button to hear the current choice.
    private func soundPicker(current: String, key: String) -> NSView {
        let popup = NSPopUpButton()
        let groups = [
            ("Ringtones", "/System/Library/PrivateFrameworks/ToneLibrary.framework/Versions/A/Resources/Ringtones"),
            ("System sounds", "/System/Library/Sounds"),
        ]
        var listed = false
        for (heading, directory) in groups {
            let files = ((try? FileManager.default.contentsOfDirectory(atPath: directory)) ?? [])
                .filter { file in [".m4r", ".aiff", ".caf", ".m4a", ".wav"].contains { file.hasSuffix($0) } }
                .sorted()
            guard !files.isEmpty else { continue }
            if popup.numberOfItems > 0 { popup.menu?.addItem(.separator()) }
            popup.addItem(withTitle: heading)
            popup.lastItem?.isEnabled = false
            for file in files {
                let path = "\(directory)/\(file)"
                popup.addItem(withTitle: "   " + (file as NSString).deletingPathExtension)
                popup.lastItem?.representedObject = path
                if path == current { popup.select(popup.lastItem); listed = true }
            }
        }
        popup.autoenablesItems = false
        popup.menu?.addItem(.separator())
        if !listed {
            let exists = FileManager.default.fileExists(atPath: current)
            popup.addItem(withTitle: URL(fileURLWithPath: current).lastPathComponent
                          + (exists ? "" : " (missing)"))
            popup.lastItem?.representedObject = current
            popup.lastItem?.toolTip = current
            popup.select(popup.lastItem)
        }
        popup.addItem(withTitle: "Choose file…")
        popup.lastItem?.tag = 2
        bind(popup) { [weak self] _ in
            guard let self else { return }
            if popup.selectedItem?.tag == 2 {
                guard let window = self.window else { return }
                let panel = NSOpenPanel()
                panel.allowedContentTypes = [.audio]
                panel.beginSheetModal(for: window) { response in
                    if response == .OK, let url = panel.url { self.save(key, url.path) } else { self.render() }
                }
            } else if let path = popup.selectedItem?.representedObject as? String {
                self.save(key, path)
            }
        }
        let play = button("Play") { [weak self] in
            self?.player?.stop()
            self?.player = NSSound(contentsOfFile: current, byReference: true)
            self?.player?.play()
        }
        return hstack([popup, play])
    }

    // MARK: - Layout

    private func row(_ title: String, key: String?, help: String?, _ control: NSView,
                     hidden: Bool = false) -> (NSView, NSView, Bool) {
        let name = label(title, size: 13, color: .labelColor)
        name.alignment = .right
        var lines: [NSView] = [control]
        let detail = [help, key.map { "config: \($0)" }].compactMap { $0 }.joined(separator: "  ·  ")
        if !detail.isEmpty { lines.append(label(detail, size: 11, color: .secondaryLabelColor)) }
        return (name, vstack(lines, spacing: 4), hidden)
    }

    private func section(_ title: String, rows: [(NSView, NSView, Bool)], note: String? = nil) -> NSView {
        let grid = NSGridView(views: rows.map { [$0.0, $0.1] })
        grid.rowSpacing = 14
        grid.columnSpacing = 14
        grid.column(at: 0).width = 170
        grid.column(at: 0).xPlacement = .trailing
        for (index, item) in rows.enumerated() {
            grid.row(at: index).yPlacement = .top
            grid.row(at: index).isHidden = item.2
        }
        var views: [NSView] = [label(title, size: 15, color: .labelColor, bold: true)]
        if let note { views.append(label(note, size: 12, color: .secondaryLabelColor)) }
        views.append(grid)
        let box = vstack(views, spacing: 10)
        return box
    }

    private func vstack(_ views: [NSView], spacing: CGFloat = 6) -> NSStackView {
        let stack = NSStackView(views: views)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = spacing
        return stack
    }

    private func hstack(_ views: [NSView]) -> NSStackView {
        let stack = NSStackView(views: views)
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 8
        return stack
    }

    private func indent(_ view: NSView) -> NSView {
        let stack = hstack([view])
        stack.edgeInsets = NSEdgeInsets(top: 0, left: 18, bottom: 0, right: 0)
        return stack
    }
}

/// Lays out top-down, so a short page sits at the top of the scroll view.
final class FlippedView: NSView {
    override var isFlipped: Bool { true }
}
