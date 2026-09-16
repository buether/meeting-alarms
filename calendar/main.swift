import EventKit
import Foundation

// usage: meeting-alarm-calendar events --from <iso8601> --to <iso8601> [--include-calendars "A,B"]
//        meeting-alarm-calendar calendars
//
// Prints JSON on stdout. Exits 1 with a message on stderr when Calendar access
// is refused, which the poller reports as a calendar failure.

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(1)
}

func argument(_ name: String) -> String? {
    let args = CommandLine.arguments
    guard let i = args.firstIndex(of: name), i + 1 < args.count else { return nil }
    return args[i + 1]
}

let isoOut: ISO8601DateFormatter = {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime]
    formatter.timeZone = TimeZone(identifier: "UTC")
    return formatter
}()

let isoIn: ISO8601DateFormatter = {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return formatter
}()

func parseDate(_ text: String, _ flag: String) -> Date {
    if let date = isoIn.date(from: text) { return date }
    let plain = ISO8601DateFormatter()
    plain.formatOptions = [.withInternetDateTime]
    if let date = plain.date(from: text) { return date }
    fail("\(flag) is not an ISO 8601 datetime: \(text)")
}

/// Meeting links live in the url, location or notes depending on who sent the
/// invitation, so every provider pattern is tried against all three.
let meetingPatterns: [NSRegularExpression] = [
    #"https?://[\w.-]*zoom\.us/(?:j|w|s|my)/[^\s<>"']+"#,
    #"https?://teams\.microsoft\.(?:com|us)/l/meetup-join/[^\s<>"']+"#,
    #"https?://teams\.live\.com/meet/[^\s<>"']+"#,
    #"https?://meet\.google\.com/[a-z]{3}-[a-z]{4}-[a-z]{3}[^\s<>"']*"#,
    #"https?://[\w.-]+\.webex\.com/[^\s<>"']*(?:meet|join)[^\s<>"']*"#,
].map { try! NSRegularExpression(pattern: $0, options: .caseInsensitive) }

func meetingURL(_ event: EKEvent) -> String? {
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

func statusName(_ status: EKEventStatus) -> String {
    switch status {
    case .confirmed: return "confirmed"
    case .tentative: return "tentative"
    case .canceled: return "canceled"
    default: return "none"
    }
}

func participantStatusName(_ status: EKParticipantStatus) -> String {
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

func email(_ participant: EKParticipant) -> String? {
    guard let url = participant.url.absoluteString as String?, url.hasPrefix("mailto:") else {
        return nil
    }
    return String(url.dropFirst("mailto:".count))
}

func requireAccess(_ store: EKEventStore) {
    if EKEventStore.authorizationStatus(for: .event) == .fullAccess { return }
    let semaphore = DispatchSemaphore(value: 0)
    var granted = false
    var failure: Error?
    store.requestFullAccessToEvents { ok, error in
        granted = ok
        failure = error
        semaphore.signal()
    }
    semaphore.wait()
    if !granted {
        fail("Calendar access denied" + (failure.map { ": \($0.localizedDescription)" } ?? ""))
    }
}

func emit(_ value: Any) {
    guard let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]) else {
        fail("could not encode JSON")
    }
    FileHandle.standardOutput.write(data)
    FileHandle.standardOutput.write(Data("\n".utf8))
}

let store = EKEventStore()
requireAccess(store)

switch CommandLine.arguments.dropFirst().first {
case "calendars":
    let rows = store.calendars(for: .event).map {
        ["title": $0.title, "source": $0.source?.title ?? ""]
    }
    emit(rows)

case "events":
    guard let from = argument("--from"), let to = argument("--to") else {
        fail("usage: meeting-alarm-calendar events --from <iso8601> --to <iso8601>")
    }
    let wanted = (argument("--include-calendars") ?? "")
        .split(separator: ",")
        .map { $0.trimmingCharacters(in: .whitespaces) }
        .filter { !$0.isEmpty }

    // Birthdays and subscribed calendars carry no attendees, so nothing in them
    // can ever alarm.
    var calendars = store.calendars(for: .event).filter {
        $0.type != .birthday && $0.type != .subscription
    }
    if !wanted.isEmpty {
        calendars = calendars.filter { wanted.contains($0.title) }
    }
    if calendars.isEmpty {
        emit([])
        exit(0)
    }

    let predicate = store.predicateForEvents(
        withStart: parseDate(from, "--from"), end: parseDate(to, "--to"), calendars: calendars
    )
    let rows: [[String: Any]] = store.events(matching: predicate).compactMap { event in
        guard let start = event.startDate, let end = event.endDate else { return nil }
        var row: [String: Any] = [
            "id": event.eventIdentifier ?? "",
            "title": event.title ?? "",
            "startDate": isoOut.string(from: start),
            "endDate": isoOut.string(from: end),
            "isAllDay": event.isAllDay,
            "status": statusName(event.status),
            "calendar": event.calendar?.title ?? "",
            "attendees": (event.attendees ?? []).map { attendee in
                [
                    "email": email(attendee) ?? "",
                    "status": participantStatusName(attendee.participantStatus),
                    "isCurrentUser": attendee.isCurrentUser,
                ] as [String: Any]
            },
        ]
        if let url = meetingURL(event) { row["meetingUrl"] = url }
        return row
    }
    emit(rows)

default:
    fail("usage: meeting-alarm-calendar (events|calendars) [options]")
}
