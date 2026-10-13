import Foundation

// `status` is where a user checks that their setup does what they
// think. Nothing here pops up or waits to be noticed: every problem has to be
// readable from the listing itself, including silence that comes from the
// config rather than from the calendar.

enum CalendarWatch: Equatable {
    case watched
    case notListed      // include_calendars is set and does not name it
    case neverRings     // birthdays and subscriptions carry no attendees
}

struct CalendarPlan {
    var rows: [(calendar: CalendarInfo, watch: CalendarWatch)]
    /// include_calendars entries that watch nothing, each with a near miss if
    /// one exists (same name, different case).
    var unmatched: [(name: String, nearMiss: String?)]
    var watchedTitles: Set<String>
}

/// Mirrors the filter `CalendarStore.events` applies when polling.
func planCalendars(_ calendars: [CalendarInfo], include: [String]) -> CalendarPlan {
    var rows: [(calendar: CalendarInfo, watch: CalendarWatch)] = []
    for calendar in calendars {
        let watch: CalendarWatch
        if calendar.neverRings {
            watch = .neverRings
        } else if include.isEmpty || include.contains(calendar.title) {
            watch = .watched
        } else {
            watch = .notListed
        }
        rows.append((calendar, watch))
    }
    let watchedTitles = Set(rows.filter { $0.watch == .watched }.map { $0.calendar.title })
    let unmatched = include.filter { !watchedTitles.contains($0) }.map { name in
        (name: name, nearMiss: calendars.first {
            !$0.neverRings && $0.title != name
                && $0.title.caseInsensitiveCompare(name) == .orderedSame
        }?.title)
    }
    let order: [CalendarWatch] = [.watched, .notListed, .neverRings]
    rows.sort {
        (order.firstIndex(of: $0.watch)!, $0.calendar.source, $0.calendar.title)
            < (order.firstIndex(of: $1.watch)!, $1.calendar.source, $1.calendar.title)
    }
    return CalendarPlan(rows: rows, unmatched: unmatched, watchedTitles: watchedTitles)
}

enum Verdict: String {
    case rings, rang, silent
}

/// What the poller will do about one upcoming event, and why, in the words the
/// listing prints.
func verdict(for event: Event, now: Date, fired: [String: FiredEvent],
             watchedTitles: Set<String>) -> (verdict: Verdict, reason: String) {
    if fired[event.key] != nil { return (.rang, "already rang") }
    if let calendar = event.calendar, !watchedTitles.contains(calendar) {
        return (.silent, "calendar not watched")
    }
    if let end = event.endDate, now >= end { return (.silent, "ended") }
    let (ok, reason) = event.eligible()
    if ok, let start = event.startDate, start <= now { return (.rings, "\(reason), in progress") }
    return (ok ? .rings : .silent, reason)
}

/// "all day", a clock time, or a weekday and clock time once past today.
func whenColumn(_ event: Event, now: Date) -> String {
    if event.isAllDay { return "all day" }
    guard let start = event.startDate else { return "??:??" }
    if Calendar.current.isDate(start, inSameDayAs: now) { return clockString(start, "HH:mm") }
    return clockString(start, "EEE HH:mm")
}

/// One line on whether alarms are actually happening. The poller runs every
/// minute, so a last success older than a few minutes means it is not running,
/// whatever launchd says.
func pollerHealth(loaded: Bool, lastOk: Double?, failingSince: Double?, lastError: String?,
                  now: Double, pollSeconds: Double) -> (ok: Bool, line: String) {
    if !loaded {
        return (false, "NOT LOADED - nothing will ring. Run: meeting-alarm install")
    }
    if let failingSince {
        let since = clockString(Date(timeIntervalSince1970: failingSince), "EEE HH:mm")
        return (false, "FAILING since \(since) - nothing will ring. \(lastError ?? "unknown error")")
    }
    guard let lastOk else {
        return (false, "NEVER RUN - no poll has succeeded yet. Wait a minute and check again.")
    }
    let age = now - lastOk
    let interval = Double(max(1, Int((pollSeconds / 60).rounded()))) * 60
    if age > max(300, 3 * interval) {
        return (false, "STALLED - last successful poll \(humanAge(age)) ago, nothing is ringing. "
            + "If the Mac just woke, check again in a minute; otherwise run: meeting-alarm install")
    }
    return (true, "running - last successful poll \(humanAge(age)) ago")
}

func humanAge(_ seconds: Double) -> String {
    let s = Int(max(0, seconds))
    if s < 90 { return "\(s)s" }
    if s < 90 * 60 { return "\(s / 60) min" }
    if s < 36 * 3600 { return "\(s / 3600) h" }
    return "\(s / 86400) days"
}
