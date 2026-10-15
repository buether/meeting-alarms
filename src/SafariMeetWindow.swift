import AppKit
import ApplicationServices

struct SafariMeetWindowState {
    var url: URL?
    var hasEmptyJoinField = false
}

enum SafariMeetWindowAction: Equatable {
    case focus(Int)
    case enterCode(Int, String)
    case openNormally
}

private func meetCode(_ url: URL) -> String? {
    guard url.scheme?.lowercased() == "https", url.host?.lowercased() == "meet.google.com",
          url.port == nil || url.port == 443, url.user == nil, url.password == nil,
          url.path.range(of: "^/[a-z]{3}-[a-z]{4}-[a-z]{3}$", options: .regularExpression) != nil
    else { return nil }
    return String(url.path.dropFirst())
}

private func isMeetHome(_ url: URL?) -> Bool {
    guard let url, url.scheme?.lowercased() == "https",
          url.host?.lowercased() == "meet.google.com", url.port == nil || url.port == 443,
          url.user == nil, url.password == nil else { return false }
    return ["", "/", "/home", "/landing"].contains(url.path)
}

/// Code entry cannot preserve URL parameters. Those links keep the normal
/// handoff, as do windows on another meeting or pages whose state is unknown.
func safariMeetWindowAction(for url: URL, windows: [SafariMeetWindowState]) -> SafariMeetWindowAction {
    guard let code = meetCode(url), url.query == nil, url.fragment == nil else { return .openNormally }
    if let index = windows.firstIndex(where: { $0.url.flatMap(meetCode) == code }) {
        return .focus(index)
    }
    if let index = windows.firstIndex(where: { isMeetHome($0.url) && $0.hasEmptyJoinField }) {
        return .enterCode(index, code)
    }
    return .openNormally
}

enum SafariMeetWindow {
    /// Requires access already granted in System Settings. Join never prompts
    /// for permission and only inspects the explicitly selected, running app.
    static func reuse(_ url: URL, in app: URL, completion: @escaping (Bool) -> Void) {
        guard AXIsProcessTrusted(), let running = NSWorkspace.shared.runningApplications.first(where: {
            $0.bundleURL?.resolvingSymlinksInPath().path == app.resolvingSymlinksInPath().path
        }) else { completion(false); return }

        DispatchQueue.global(qos: .userInitiated).async {
            let application = AXUIElementCreateApplication(running.processIdentifier)
            let access = WindowAccess()
            let windows = access.elements(application, kAXWindowsAttribute)
            let states = windows.map(access.state)
            let result: Bool
            switch safariMeetWindowAction(for: url, windows: states) {
            case .focus(let index):
                result = access.state(windows[index]).url.flatMap(meetCode) == meetCode(url)
                    && access.raise(windows[index])
            case .enterCode(let index, let code):
                result = access.enter(code, in: windows[index])
            case .openNormally:
                result = false
            }
            DispatchQueue.main.async {
                if result { running.activate(options: [.activateIgnoringOtherApps]) }
                completion(result)
            }
        }
    }
}

private struct WindowAccess {
    private let deadline = Date().addingTimeInterval(3)

    private func value(_ element: AXUIElement, _ attribute: String) -> CFTypeRef? {
        guard Date() < deadline else { return nil }
        AXUIElementSetMessagingTimeout(element, 0.15)
        var result: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &result) == .success else {
            return nil
        }
        return result
    }

    func elements(_ element: AXUIElement, _ attribute: String) -> [AXUIElement] {
        value(element, attribute) as? [AXUIElement] ?? []
    }

    /// Stops at the document boundary so an embedded frame cannot select a window.
    private func document(_ window: AXUIElement) -> AXUIElement? {
        var pending = [window]
        for _ in 0..<80 {
            guard !pending.isEmpty else { break }
            let element = pending.removeFirst()
            if value(element, kAXRoleAttribute) as? String == "AXWebArea" { return element }
            pending.append(contentsOf: elements(element, kAXChildrenAttribute))
        }
        return nil
    }

    private func documentURL(_ document: AXUIElement) -> URL? {
        if let url = value(document, kAXURLAttribute) as? URL { return url }
        return (value(document, kAXURLAttribute) as? String).flatMap(URL.init(string:))
    }

    private func joinControls(_ document: AXUIElement) -> (field: AXUIElement, button: AXUIElement)? {
        var fields: [AXUIElement] = []
        var buttons: [AXUIElement] = []
        var pending = elements(document, kAXChildrenAttribute)
        for _ in 0..<400 {
            guard !pending.isEmpty else { break }
            let element = pending.removeFirst()
            let role = value(element, kAXRoleAttribute) as? String
            if role == "AXWebArea" || role == kAXSheetRole { continue }
            if role == kAXTextFieldRole || role == kAXButtonRole {
                let labels = [kAXTitleAttribute, kAXDescriptionAttribute, kAXPlaceholderValueAttribute]
                    .compactMap { value(element, $0) as? String }
                if role == kAXTextFieldRole && labels.contains("Enter a code or nickname") {
                    fields.append(element)
                }
                if role == kAXButtonRole && labels.contains("Join") { buttons.append(element) }
            }
            pending.append(contentsOf: elements(element, kAXChildrenAttribute))
        }
        guard pending.isEmpty, fields.count == 1, buttons.count == 1 else { return nil }
        return (fields[0], buttons[0])
    }

    func state(_ window: AXUIElement) -> SafariMeetWindowState {
        guard let document = document(window) else { return SafariMeetWindowState() }
        let url = documentURL(document)
        var empty = false
        if isMeetHome(url), !elements(window, kAXChildrenAttribute).contains(where: {
            value($0, kAXRoleAttribute) as? String == kAXSheetRole
        }),
           let controls = joinControls(document) {
            var settable: DarwinBoolean = false
            empty = value(controls.field, kAXValueAttribute) as? String == ""
                && value(controls.field, kAXEnabledAttribute) as? Bool == true
                && AXUIElementIsAttributeSettable(controls.field, kAXValueAttribute as CFString,
                                                  &settable) == .success && settable.boolValue
        }
        return SafariMeetWindowState(url: url, hasEmptyJoinField: empty)
    }

    func raise(_ window: AXUIElement) -> Bool {
        guard Date() < deadline else { return false }
        AXUIElementSetMessagingTimeout(window, 0.15)
        _ = AXUIElementSetAttributeValue(window, kAXMinimizedAttribute as CFString, kCFBooleanFalse)
        return AXUIElementPerformAction(window, kAXRaiseAction as CFString) == .success
    }

    func enter(_ code: String, in window: AXUIElement) -> Bool {
        guard state(window).hasEmptyJoinField, let document = document(window),
              let controls = joinControls(document), raise(window),
              isMeetHome(documentURL(document)),
              value(controls.field, kAXValueAttribute) as? String == "",
              AXUIElementSetAttributeValue(controls.field, kAXFocusedAttribute as CFString,
                                            kCFBooleanTrue) == .success,
              AXUIElementSetAttributeValue(controls.field, kAXValueAttribute as CFString,
                                            code as CFString) == .success else { return false }
        var submitted = false
        defer {
            if !submitted, isMeetHome(documentURL(document)),
               value(controls.field, kAXValueAttribute) as? String == code {
                _ = AXUIElementSetAttributeValue(controls.field, kAXValueAttribute as CFString, "" as CFString)
            }
        }
        for _ in 0..<10 {
            guard isMeetHome(documentURL(document)),
                  value(controls.field, kAXValueAttribute) as? String == code else { return false }
            if value(controls.button, kAXEnabledAttribute) as? Bool == true {
                submitted = AXUIElementPerformAction(controls.button, kAXPressAction as CFString) == .success
                return submitted
            }
            Thread.sleep(forTimeInterval: 0.05)
        }
        return false
    }
}
