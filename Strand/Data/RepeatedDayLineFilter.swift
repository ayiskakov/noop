import Foundation

/// Withholds a re-score's per-day diagnostic line when the previous pass already printed the same text
/// for the same day (W07-005).
///
/// Every re-score replays each scored day's lines (`rhr`, `resp`, `sleep`, `hrv`, `hrv diag`, `effort`,
/// `workout detect`, `sleep-detect`, …) into the strap log, and on a strap that offloads every few minutes
/// most of them are byte-identical to the last pass: on the owner's 2026-09-27 log, 733 of 840 over 12
/// passes. They were the largest share of the log ring and limited how far back an export reached.
///
/// A line is keyed by its text through its `day=YYYY-MM-DD` token plus its occurrence within the pass
/// (a day can carry two `effort bout` lines), so a changed value on the same key prints. A line with no
/// day token always prints. An unchanged line prints again once its last print is `refreshAfter` old,
/// so every scored day keeps a recent copy in the exports: the durable tail keeps 2,000 lines, which is
/// about 75 min at that log's density once the repeats are gone, and the live ring about 3 h.
///
/// The pass's `summaryLine` counts what it withheld and names the oldest print it relies on, so a reader
/// whose export starts after that time knows the copy is not in it. Lines are compared before
/// `LiveState.redactPii`: route only counts-and-day-key lines through here, never one carrying an
/// identifier, or two lines the scrub would make identical could compare as different (and the reverse).
struct RepeatedDayLineFilter {
    static let refreshAfter: TimeInterval = 3_600

    private var lastPrint: [String: (line: String, at: Date)] = [:]
    private var occurrences: [String: Int] = [:]
    private(set) var withheld = 0
    private var oldestWithheldPrint: Date?

    /// Start a pass: occurrence indices restart, and prints older than `refreshAfter` are dropped, since
    /// they can no longer withhold anything; that keeps the table to about an hour of keys. `admit` still
    /// judges the age itself, because a pass runs for minutes and can cross the hour after it began.
    mutating func beginPass(now: Date) {
        occurrences = [:]
        withheld = 0
        oldestWithheldPrint = nil
        lastPrint = lastPrint.filter { now.timeIntervalSince($0.value.at) < Self.refreshAfter }
    }

    /// Whether to print `line` now; records the print when it says yes.
    mutating func admit(_ line: String, now: Date) -> Bool {
        guard let base = Self.dayKey(of: line) else { return true }
        let n = occurrences[base, default: 0]
        occurrences[base] = n + 1
        let key = "\(base)#\(n)"
        if let last = lastPrint[key], last.line == line, now.timeIntervalSince(last.at) < Self.refreshAfter {
            withheld += 1
            oldestWithheldPrint = min(oldestWithheldPrint ?? last.at, last.at)
            return false
        }
        lastPrint[key] = (line, now)
        return true
    }

    /// One line accounting for this pass's withheld lines; nil when it withheld none. The time is local
    /// `HH:mm:ss`, the stamp the Collector's lines around it carry.
    func summaryLine() -> String? {
        guard withheld > 0, let oldest = oldestWithheldPrint else { return nil }
        return "re-score: \(withheld) per-day line(s) unchanged since their last print, not repeated "
            + "(oldest print \(Self.timeFormatter.string(from: oldest)))"
    }

    static let timeFormatter: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "HH:mm:ss"; return f
    }()

    /// The line's text through its first `day=YYYY-MM-DD` token, or nil when it has none.
    static func dayKey(of line: String) -> String? {
        guard let range = line.range(of: #"day=\d{4}-\d{2}-\d{2}"#, options: .regularExpression) else { return nil }
        return String(line[..<range.upperBound])
    }
}
