import Foundation

/// One rate-limit window (the 5-hour session limit or the 7-day weekly limit),
/// as snapshotted from Claude Code's statusLine payload by cc-statusline.sh.
struct UsageWindow: Codable {
    let usedPercentage: Double   // 0–100
    let resetsAt: Double         // unix epoch seconds

    enum CodingKeys: String, CodingKey {
        case usedPercentage = "used_percentage"
        case resetsAt = "resets_at"
    }
}

/// The account's current subscription usage: the most recent snapshot the
/// statusLine hook was able to capture. `updatedAt` is when those numbers were
/// last seen — usage only refreshes while a Claude session is running, so a
/// stale timestamp is expected (and surfaced to the user) when nothing's active.
struct AccountUsage: Codable {
    let fiveHour: UsageWindow?
    let sevenDay: UsageWindow?
    let updatedAt: Double

    enum CodingKeys: String, CodingKey {
        case fiveHour = "five_hour"
        case sevenDay = "seven_day"
        case updatedAt
    }

    /// The window closest to its limit — what the always-visible menu-bar
    /// percentage reflects, since that's the one about to shut you out.
    var mostConstrained: UsageWindow? {
        switch (fiveHour, sevenDay) {
        case let (a?, b?): return a.usedPercentage >= b.usedPercentage ? a : b
        case let (a?, nil): return a
        case let (nil, b?): return b
        case (nil, nil): return nil
        }
    }

    /// Highest used-percentage across both windows, or nil if neither is known.
    var peakPercent: Int? {
        guard let w = mostConstrained else { return nil }
        return Int(w.usedPercentage.rounded())
    }
}

/// Reads (and caches) the usage snapshot written by cc-statusline.sh. Lives in
/// the same state directory the session watcher already observes, so a new
/// snapshot triggers the app's existing refresh — no extra timer needed.
final class UsageStore {
    private let path: String

    init(stateDir: String) {
        self.path = (stateDir as NSString).appendingPathComponent("usage.json")
    }

    /// The current snapshot, or nil if usage has never been captured (no file,
    /// or an unreadable/partial one — a bad read just yields "no data").
    func load() -> AccountUsage? {
        guard let data = FileManager.default.contents(atPath: path) else { return nil }
        return try? JSONDecoder().decode(AccountUsage.self, from: data)
    }
}

/// Percentages at/above which a window is treated as "hot" — the menu-bar
/// number turns red so you notice before you're locked out.
let kUsageHotPercent = 85

// MARK: - display helpers

/// A short human "resets in …" phrase for a window's reset time, e.g. "resets
/// in 3h", "resets in 2d", or "resets now" once the window has rolled over.
func resetPhrase(_ resetsAt: Double, now: Double = Date().timeIntervalSince1970) -> String {
    let secs = resetsAt - now
    if secs <= 60 { return "resets now" }
    let mins = Int((secs / 60).rounded())
    if mins < 60 { return "resets in \(mins)m" }
    let hours = mins / 60
    if hours < 24 { return "resets in \(hours)h" }
    let days = hours / 24
    return "resets in \(days)d"
}

/// A short "updated …" phrase for the snapshot's age, used to make the
/// only-refreshes-while-running caveat concrete: "updated just now", "12m ago".
func freshnessPhrase(_ updatedAt: Double, now: Double = Date().timeIntervalSince1970) -> String {
    let secs = max(0, now - updatedAt)
    if secs < 90 { return "updated just now" }
    let mins = Int((secs / 60).rounded())
    if mins < 60 { return "updated \(mins)m ago" }
    let hours = mins / 60
    if hours < 24 { return "updated \(hours)h ago" }
    let days = hours / 24
    return "updated \(days)d ago"
}
