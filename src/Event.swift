import Foundation

/// A meeting still in progress alarms however late the Mac woke up. The lookback
/// only bounds how far back a poll looks for one; the end time makes the decision.
let lateLookbackSeconds: Double = 8 * 3600

let skipStatuses: Set<String> = ["declined", "tentative"]

struct Attendee {
    var email: String?
    var status: String
    var isCurrentUser: Bool
}

/// Every field EventKit can leave empty is optional here. The poller alarms on
/// what it cannot read, so `nil` has to survive as far as `classify`.
struct Event {
    var id: String?
    var title: String?
    var startDate: Date?
    var endDate: Date?
    var isAllDay = false
    var status = "none"
    var calendar: String?
    /// `nil` means the attendee list was unreadable; `[]` means there really are none.
    var attendees: [Attendee]?
    var meetingURL: String?

    var displayTitle: String {
        guard let title, !title.isEmpty else { return "(untitled)" }
        return title
    }

    func startOr(_ fallback: Date) -> Date { startDate ?? fallback }

    /// Recurring occurrences share an id, so the start time is part of the key.
    ///
    /// An event with no readable start still needs a stable key, or it would alarm
    /// again every poll.
    var key: String {
        let name = (id?.isEmpty == false) ? id! : displayTitle
        let stamp = startDate.map { String(Int($0.timeIntervalSince1970)) } ?? "unknown"
        return "\(name)@\(stamp)"
    }

    /// The current user's response, or "pending" when EventKit marked no attendee as me.
    var myStatus: String {
        guard let mine = attendees?.first(where: { $0.isCurrentUser }) else { return "pending" }
        return mine.status
    }

    /// Non-timing filters.
    func eligible() -> (ok: Bool, reason: String) {
        if isAllDay { return (false, "all-day") }
        if status == "canceled" { return (false, "canceled") }
        if let attendees, !attendees.contains(where: { !$0.isCurrentUser }) {
            return (false, "no other attendees")
        }
        let mine = myStatus
        if skipStatuses.contains(mine) { return (false, "my status \(mine)") }
        return (true, "my status \(mine)")
    }

    /// Decide whether one calendar event should alarm at `now`.
    ///
    /// A meeting that has ended is the only reason to stay silent about an event
    /// that is otherwise eligible. Anything unreadable alarms, because a missed
    /// meeting costs more than a spurious alarm.
    func classify(now: Date, fired: [String: FiredEvent], cfg: Config) -> (fire: Bool, reason: String) {
        let (ok, reason) = eligible()
        if !ok { return (false, reason) }
        if fired[key] != nil { return (false, "already fired") }
        if let endDate, now >= endDate { return (false, "already ended") }
        guard let startDate else { return (true, "\(reason), start time unreadable") }
        let delta = startDate.timeIntervalSince(now)
        if delta >= cfg.leadSeconds + cfg.pollSeconds {
            return (false, "starts in \(Int(delta))s")
        }
        if delta < 0 {
            return (true, "\(reason), started \(Int(-delta))s ago and still running")
        }
        return (true, "\(reason), starts in \(Int(delta))s")
    }
}

func selectDue(_ events: [Event], now: Date, fired: [String: FiredEvent], cfg: Config) -> [Event] {
    events.filter { $0.classify(now: now, fired: fired, cfg: cfg).fire }
}

/// Events whose start falls in [lo, hi). An unreadable start is kept for classify.
func within(_ events: [Event], _ lo: Date, _ hi: Date) -> [Event] {
    events.filter { event in
        guard let start = event.startDate else { return true }
        return start >= lo && start < hi
    }
}

func fireWindow(now: Date, cfg: Config) -> (lo: Date, hi: Date) {
    (now.addingTimeInterval(-lateLookbackSeconds),
     now.addingTimeInterval(cfg.leadSeconds + cfg.pollSeconds + 60))
}

func sortByStart(_ events: [Event]) -> [Event] {
    events.sorted { ($0.startDate ?? .distantPast) < ($1.startDate ?? .distantPast) }
}

// MARK: - Formatting

func localISO(_ date: Date) -> String {
    let f = ISO8601DateFormatter()
    f.formatOptions = [.withInternetDateTime]
    f.timeZone = TimeZone.current
    return f.string(from: date)
}

func parseTimestamp(_ text: String) -> Date? {
    let withFraction = ISO8601DateFormatter()
    withFraction.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    if let date = withFraction.date(from: text) { return date }
    let plain = ISO8601DateFormatter()
    plain.formatOptions = [.withInternetDateTime]
    return plain.date(from: text)
}

func clockString(_ date: Date, _ format: String) -> String {
    let f = DateFormatter()
    f.dateFormat = format
    return f.string(from: date)
}
