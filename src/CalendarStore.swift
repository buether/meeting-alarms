import EventKit
import Foundation

struct CalendarError: Error, CustomStringConvertible {
    var description: String
    init(_ message: String) { description = message }
}

/// Meeting links live in the url, location or notes depending on who sent the
/// invitation, so every provider pattern is tried against all three.
private let meetingPatterns: [NSRegularExpression] = [
    #"https?://[\w.-]*zoom\.us/(?:j|w|s|my)/[^\s<>"']+"#,
    #"https?://teams\.microsoft\.(?:com|us)/l/meetup-join/[^\s<>"']+"#,
    #"https?://teams\.live\.com/meet/[^\s<>"']+"#,
    #"https?://meet\.google\.com/[a-z]{3}-[a-z]{4}-[a-z]{3}[^\s<>"']*"#,
    #"https?://[\w.-]+\.webex\.com/[^\s<>"']*(?:meet|join)[^\s<>"']*"#,
].map { try! NSRegularExpression(pattern: $0, options: .caseInsensitive) }

private func meetingURL(_ event: EKEvent) -> String? {
    let haystacks = [event.url?.absoluteString, event.location, event.notes].compactMap { $0 }
    for text in haystacks {
        let range = NSRange(text.startIndex..., in: text)
        for pattern in meetingPatterns {
            if let match = pattern.firstMatch(in: text, range: range),
               let found = Range(match.range, in: text) {
                return String(text[found])
            }
        }
    }
    return nil
}

private func statusName(_ status: EKEventStatus) -> String {
    switch status {
    case .confirmed: return "confirmed"
    case .tentative: return "tentative"
    case .canceled: return "canceled"
    default: return "none"
    }
}

private func participantStatusName(_ status: EKParticipantStatus) -> String {
    switch status {
    case .accepted: return "accepted"
    case .declined: return "declined"
    case .tentative: return "tentative"
    case .pending: return "pending"
    case .delegated: return "delegated"
    case .completed: return "completed"
    case .inProcess: return "inProcess"
    default: return "unknown"
    }
}

private func email(_ participant: EKParticipant) -> String? {
    let url = participant.url.absoluteString
    guard url.hasPrefix("mailto:") else { return nil }
    return String(url.dropFirst("mailto:".count))
}

struct CalendarInfo {
    var title: String
    var source: String
}

enum CalendarStore {
    private static let store = EKEventStore()

    /// Blocks on the permission prompt the first time. The alarm bundle is what
    /// macOS attributes the request to, so this is the only thing the user sees.
    static func requireAccess() throws {
        if EKEventStore.authorizationStatus(for: .event) == .fullAccess { return }
        let semaphore = DispatchSemaphore(value: 0)
        var granted = false
        var failure: Error?
        store.requestFullAccessToEvents { ok, error in
            granted = ok
            failure = error
            semaphore.signal()
        }
        if semaphore.wait(timeout: .now() + 120) == .timedOut {
            throw CalendarError("calendar access request timed out (waiting on a permission prompt?)")
        }
        if !granted {
            throw CalendarError("Calendar access denied"
                + (failure.map { ": \($0.localizedDescription)" } ?? ""))
        }
    }

    static func calendars() throws -> [CalendarInfo] {
        try requireAccess()
        return store.calendars(for: .event).map {
            CalendarInfo(title: $0.title, source: $0.source?.title ?? "")
        }
    }

    static func events(cfg: Config, from: Date, to: Date) throws -> [Event] {
        try requireAccess()

        // Birthdays and subscribed calendars carry no attendees, so nothing in them
        // can ever alarm.
        var calendars = store.calendars(for: .event).filter {
            $0.type != .birthday && $0.type != .subscription
        }
        if !cfg.includeCalendars.isEmpty {
            calendars = calendars.filter { cfg.includeCalendars.contains($0.title) }
        }
        // An empty array would mean "every calendar" to predicateForEvents, which is
        // the opposite of what include_calendars matching nothing should produce.
        if calendars.isEmpty { return [] }

        let predicate = store.predicateForEvents(withStart: from, end: to, calendars: calendars)
        return store.events(matching: predicate).map { event in
            // An event with no readable start or end is kept: classify decides, and
            // it alarms on what it cannot read.
            Event(
                id: event.eventIdentifier,
                title: event.title,
                startDate: event.startDate,
                endDate: event.endDate,
                isAllDay: event.isAllDay,
                status: statusName(event.status),
                calendar: event.calendar?.title,
                attendees: event.attendees.map { list in
                    list.map {
                        Attendee(email: email($0),
                                 status: participantStatusName($0.participantStatus),
                                 isCurrentUser: $0.isCurrentUser)
                    }
                },
                meetingURL: meetingURL(event)
            )
        }
    }

    static func checkCalendars(cfg: Config) throws {
        guard let expected = cfg.expectedSource else { return }
        let found = try calendars()
        if !found.contains(where: { $0.source == expected }) {
            throw CalendarError(
                "no calendar from source \"\(expected)\"; is the account still signed in?")
        }
    }
}

// MARK: - Fixtures

extension Event {
    /// Reads the JSON shape the poller used to receive on a pipe, so `poll
    /// --events-file` can still replay a recorded day without a calendar.
    init(json: [String: Any]) {
        id = json["id"] as? String
        title = json["title"] as? String
        startDate = (json["startDate"] as? String).flatMap(parseTimestamp)
        endDate = (json["endDate"] as? String).flatMap(parseTimestamp)
        isAllDay = (json["isAllDay"] as? NSNumber)?.boolValue ?? false
        status = json["status"] as? String ?? "none"
        calendar = json["calendar"] as? String
        attendees = (json["attendees"] as? [[String: Any]]).map { list in
            list.map {
                Attendee(email: $0["email"] as? String,
                         status: $0["status"] as? String ?? "unknown",
                         isCurrentUser: ($0["isCurrentUser"] as? NSNumber)?.boolValue ?? false)
            }
        }
        meetingURL = json["meetingUrl"] as? String
    }

    static func load(fixture path: String) throws -> [Event] {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)) else {
            throw CalendarError("could not read \(path)")
        }
        guard let rows = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]] else {
            throw CalendarError("\(path) is not a JSON array of events")
        }
        return rows.map(Event.init(json:))
    }
}
