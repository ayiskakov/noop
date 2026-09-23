import Foundation

// SleepRegularity.swift — the Sleep Regularity Index (SRI), from sleep sessions.
//
// SRI = 200 · P(same sleep/wake state at t and t + 24 h) − 100, over 30-second epochs (Phillips et al.,
// Sci Rep 2017; the device-measured mortality evidence is Windred, SLEEP 2024 and Cribb, eLife 2023).
// 100 means sleeping and waking at identical clock times every day; 0 means the states at t and t + 24 h
// agree no more often than chance.
//
// It measures TIMING, not duration: two nights of 7 h, one from 23:00 and one from 03:00, agree on only
// three of the fourteen hours between them, while a 1 − CV of duration would call them identical.
//
// ── WHICH EPOCHS COUNT ────────────────────────────────────────────────────────────────────────────
//
// A strap that was not worn looks exactly like a person who stayed awake. So time is cut into local
// noon-to-noon "sleep days", and a day only counts when at least one session overlaps it; a pair (t, t + 24 h)
// is only scored when BOTH its days count. An unworn night drops out of the index instead of reading as
// the most irregular night of the month.
public enum SleepRegularity {

    public static let epochSeconds = 30
    static let epochsPerDay = 86_400 / epochSeconds
    /// Fewest scored day pairs before an index is reported.
    public static let minPairs = 5

    /// A half-open [start, end) span in unix seconds.
    public struct Span: Equatable, Sendable {
        public let start: Double
        public let end: Double
        public init(start: Double, end: Double) { self.start = start; self.end = end }
    }

    /// One recorded sleep session: its span, and the wake stretches inside it (asleep = span − wake).
    public struct Session: Equatable, Sendable {
        public let span: Span
        public let wake: [Span]
        public init(start: Double, end: Double, wake: [Span] = []) {
            self.span = Span(start: start, end: end); self.wake = wake
        }
    }

    /// A session from a stored sleep block: its onset/end and the `"wake"` segments of a computed
    /// `[{start,end,stage}]` staging array. Any other staging shape (an imported minute dictionary, which
    /// carries no clock times) or unparseable JSON yields a session with no wake stretches — the span is
    /// still the best timing evidence there is. Nil for an empty or inverted span.
    public static func session(startTs: Int, endTs: Int, stagesJSON: String?) -> Session? {
        guard endTs > startTs else { return nil }
        var wake: [Span] = []
        if let data = stagesJSON?.data(using: .utf8),
           let segments = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]] {
            for seg in segments {
                let stage = (seg["stage"] as? String)?.lowercased()
                guard stage == "wake" || stage == "awake",
                      let s = (seg["start"] as? NSNumber)?.doubleValue,
                      let e = (seg["end"] as? NSNumber)?.doubleValue, e > s else { continue }
                wake.append(Span(start: s, end: e))
            }
        }
        return Session(start: Double(startTs), end: Double(endTs), wake: wake)
    }

    /// Local sleep day `d` runs from noon of local day `d` (days since 1970-01-01) to the next noon.
    static func dayStart(_ day: Int, tzOffsetSec: Int) -> Double {
        Double(day * 86_400 + 43_200 - tzOffsetSec)
    }

    static func day(containing ts: Double, tzOffsetSec: Int) -> Int {
        Int(((ts + Double(tzOffsetSec) - 43_200) / 86_400).rounded(.down))
    }

    /// The asleep state of every epoch of sleep day `day`, or nil when no session overlaps that day.
    static func states(day: Int, sessions: [Session], tzOffsetSec: Int) -> [Bool]? {
        let start = dayStart(day, tzOffsetSec: tzOffsetSec), end = start + 86_400
        let overlapping = sessions.filter { $0.span.end > start && $0.span.start < end }
        guard !overlapping.isEmpty else { return nil }
        var asleep = [Bool](repeating: false, count: epochsPerDay)
        func paint(_ s: Span, _ value: Bool) {
            // An epoch takes the state at its midpoint.
            let from = Int(((max(s.start, start) - start) / Double(epochSeconds) - 0.5).rounded(.up))
            let to = Int(((min(s.end, end) - start) / Double(epochSeconds) - 0.5).rounded(.up))
            guard to > from else { return }
            for e in max(0, from)..<min(epochsPerDay, to) { asleep[e] = value }
        }
        for session in overlapping {
            paint(session.span, true)
            for w in session.wake { paint(w, false) }
        }
        return asleep
    }

    /// Per scored pair, keyed by the EARLIER sleep day: the fraction of its epochs whose state matches
    /// the same clock time 24 h later. Pairs where either day has no session are absent (see header).
    /// Computed once, so an index over any window is just an average of these.
    public static func dailyAgreement(sessions: [Session], tzOffsetSec: Int) -> [Int: Double] {
        guard let first = sessions.map({ $0.span.start }).min(),
              let last = sessions.map({ $0.span.end }).max() else { return [:] }
        let firstDay = day(containing: first, tzOffsetSec: tzOffsetSec)
        let lastDay = day(containing: last - 1, tzOffsetSec: tzOffsetSec)
        guard lastDay > firstDay else { return [:] }
        var out: [Int: Double] = [:]
        var previous = states(day: firstDay, sessions: sessions, tzOffsetSec: tzOffsetSec)
        for d in (firstDay + 1)...lastDay {
            let current = states(day: d, sessions: sessions, tzOffsetSec: tzOffsetSec)
            if let a = previous, let b = current {
                var same = 0
                for e in 0..<epochsPerDay where a[e] == b[e] { same += 1 }
                out[d - 1] = Double(same) / Double(epochsPerDay)
            }
            previous = current
        }
        return out
    }

    /// SRI over the pairs whose earlier day falls in `fromDay...toDay`. Nil below `minPairs`.
    public static func index(agreement: [Int: Double], fromDay: Int, toDay: Int) -> Double? {
        let xs = agreement.filter { $0.key >= fromDay && $0.key <= toDay }.map(\.value)
        guard xs.count >= minPairs else { return nil }
        return 200 * xs.reduce(0, +) / Double(xs.count) - 100
    }

    /// SRI over every scored pair in `sessions`. Nil below `minPairs`.
    public static func index(sessions: [Session], tzOffsetSec: Int) -> Double? {
        let a = dailyAgreement(sessions: sessions, tzOffsetSec: tzOffsetSec)
        guard let lo = a.keys.min(), let hi = a.keys.max() else { return nil }
        return index(agreement: a, fromDay: lo, toDay: hi)
    }
}
