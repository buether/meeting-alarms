import Foundation

// Calendar accounts can stop delivering invites without any error EventKit can
// report: an account removed or switched off for Calendars just vanishes, and
// one whose password expired keeps its calendars and its stale events while new
// invites stop arriving. So the poller remembers every account it has seen.
// A vanished one is a problem. A quiet one is shown with its newest change as
// evidence, since a healthy personal account can go days without one.

/// Missing for this long before it counts as gone, so a sync restart or a
/// login that is still bringing accounts up does not read as a sign-out.
let accountGoneAfterSeconds: Double = 600
/// No event changed in this long on an account that syncs is worth a look.
let accountQuietAfterSeconds: Double = 14 * 86400

struct LiveAccount: Equatable {
    var id: String
    var title: String
    var calendars: [String]
    /// "On My Mac" calendars cannot be signed out of and do not sync.
    var local: Bool
}

struct AccountRecord: Equatable {
    var title: String
    var calendars: [String]
    var local: Bool
    var firstSeen: Double
    var lastSeen: Double
    var newestChange: Double?
}

/// Folds one scan into what is remembered. An account that disappears and
/// comes back under a new identifier (removed and added again) replaces the
/// old record rather than leaving it reported as gone.
func updateAccounts(_ known: [String: AccountRecord], live: [LiveAccount], now: Double,
                    activity: [String: Double]? = nil) -> [String: AccountRecord] {
    var result = known
    for account in live {
        var record = result[account.id] ?? AccountRecord(
            title: account.title, calendars: account.calendars, local: account.local,
            firstSeen: now, lastSeen: now, newestChange: nil)
        record.title = account.title
        record.calendars = account.calendars
        record.local = account.local
        record.lastSeen = now
        if let activity { record.newestChange = activity[account.id] }
        result[account.id] = record
    }
    let liveIDs = Set(live.map(\.id))
    for (id, old) in known where !liveIDs.contains(id) {
        let replaced = live.contains { other in
            other.title == old.title && (result[other.id]?.firstSeen ?? now) > old.lastSeen
        }
        if replaced { result.removeValue(forKey: id) }
    }
    return result
}

enum AccountProblem: Equatable {
    case gone(title: String, calendars: [String], lastSeen: Double)
    case expectedMissing(name: String)

    var line: String {
        switch self {
        case let .gone(title, calendars, lastSeen):
            let when = clockString(Date(timeIntervalSince1970: lastSeen), "EEE d MMM HH:mm")
            return "ACCOUNT GONE - \(title) (\(calendars.joined(separator: ", "))), last seen \(when). "
                + "Its invites no longer reach this Mac. Sign in again under System Settings > "
                + "Internet Accounts with Calendars on. Removed it on purpose? meeting-alarm accounts --forget"
        case let .expectedMissing(name):
            return "ACCOUNT MISSING - expected_source is \"\(name)\", but no account by that name has calendars here."
        }
    }
}

func accountProblems(_ known: [String: AccountRecord], now: Double,
                     expectedSource: String?) -> [AccountProblem] {
    var problems: [AccountProblem] = known.values
        .filter { now - $0.lastSeen > accountGoneAfterSeconds }
        .sorted { $0.lastSeen < $1.lastSeen }
        .map { .gone(title: $0.title, calendars: $0.calendars, lastSeen: $0.lastSeen) }
    if let expectedSource,
       !known.values.contains(where: { $0.title == expectedSource && now - $0.lastSeen <= accountGoneAfterSeconds }) {
        problems.append(.expectedMissing(name: expectedSource))
    }
    return problems
}

/// "newest change 3 days ago", or QUIET once it is long enough to be worth
/// checking. Never counted as a problem: quiet is normal for some accounts.
func accountActivityLine(_ record: AccountRecord, now: Double) -> (quiet: Bool, text: String) {
    if record.local { return (false, "on this Mac, nothing to sign in to") }
    guard let newest = record.newestChange else {
        return (false, "no events in the last 30 or next 60 days")
    }
    let age = now - newest
    if age > accountQuietAfterSeconds {
        return (true, "QUIET - newest change \(humanAge(age)) ago. If you have had invites since, "
            + "this account may be signed out: check System Settings > Internet Accounts.")
    }
    return (false, "newest change \(humanAge(age)) ago")
}
