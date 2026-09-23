import Foundation

// PaceOfAgingEngine.swift — "is my Body Age heading up or down, and how fast?", as a multiple of time.
//
// INDEPENDENT implementation of WHOOP's published definition of Pace of Aging (white paper rev.
// 2025-09-04, p.19). NOT medical advice; a trend in a wellness estimate, never a clinical rate of aging.
//
// ── THE PROJECTION (`project`) ────────────────────────────────────────────────────────────────────
//
// Hold the last 30 days' averages for the next six months. The six-month Body Age window would then hold
// nothing but those habits, so the projected Body Age is
//
//     projected = current + 0.5 y + (Δ(recent) − Δ(six-month))
//
// and the pace is how fast Body Age moves over those six months: (projected − current) / 0.5 y. Someone
// whose last month looks like their last six ages at exactly 1×; better habits lately read below 1×.
//
// Both windows are scored over the SAME set of drivers. If a lean-mass reading arrived last week, the
// recent window has a driver the six-month one lacks, and the difference would read "you connected a
// scale" as "you aged". So each window is restricted to the drivers both carry before they are compared.
//
// ── THE MARGIN ────────────────────────────────────────────────────────────────────────────────────
//
// One month is a noisy sample of someone's habits. The spread of Δ across the non-overlapping 30-day
// windows of the six months is exactly how far one month wanders from the half-year it sits in, so it is
// the margin's scale: ± 1.96 · sd / 0.5 y. With fewer than three windows the spread is not measurable and
// a prior (`priorWindowSD`) is used, flagged `lowerConfidence`. When the margin covers 1× the honest
// readout is "holding steady", not a figure.
public enum PaceOfAgingEngine {

    // MARK: - Projection (WHOOP's definition)

    /// The "recent habits" window, days.
    public static let projectionRecentDays = 30
    /// The Body Age window, days (six months).
    public static let baselineWindowDays = 182
    /// How far ahead the recent habits are held, years.
    public static let projectionYears = 0.5
    /// Fewest non-overlapping monthly windows whose spread is measured rather than assumed.
    public static let minWindowsForSpread = 3
    /// Assumed month-to-month SD of Δ, years, until `minWindowsForSpread` windows exist.
    public static let priorWindowSD = 0.5
    /// Floor on the measured SD, so a suspiciously flat history cannot claim a razor-thin margin.
    public static let minWindowSD = 0.1

    public struct Projection: Equatable, Sendable {
        /// Body Age years gained per calendar year if the last 30 days hold, clamped to [minPace, maxPace].
        public let pace: Double
        /// The six-month Body Age the projection starts from (the headline).
        public let currentBodyAge: Double
        /// Body Age six months out if the last 30 days hold: current + 0.5 y · pace.
        public let projectedBodyAge: Double
        /// ± band on `pace` at 95 %, in the same × units.
        public let paceMargin: Double
        /// True when the margin covers 1× — show "holding steady", not a figure.
        public let isSteady: Bool
        /// True when the margin rests on the prior because too few monthly windows exist.
        public let lowerConfidence: Bool
        /// The drivers both windows were compared over, sorted.
        public let comparedKeys: [String]
    }

    /// Project the pace of aging. `baseline` is the six-month window, `recent` the last 30 days, and
    /// `monthlyWindows` the non-overlapping 30-day windows of the six months (any order). Nil when either
    /// window is unscorable or they share fewer than `VitalityEngine.minFactors` drivers.
    public static func project(baseline: VitalityEngine.Inputs, recent: VitalityEngine.Inputs,
                               monthlyWindows: [VitalityEngine.Inputs] = []) -> Projection? {
        guard let current = VitalityEngine.compute(baseline) else { return nil }
        let baseKeys = Set(VitalityEngine.contributions(baseline).map(\.key))
        let recentKeys = Set(VitalityEngine.contributions(recent).map(\.key))
        let common = baseKeys.intersection(recentKeys)
        guard common.count >= VitalityEngine.minFactors,
              let base = VitalityEngine.compute(baseline.restricted(to: common)),
              let rec = VitalityEngine.compute(recent.restricted(to: common)) else { return nil }

        let drift = rec.unclampedBodyAge - base.unclampedBodyAge      // years of Body Age, recent vs 6 mo
        let rawPace = 1 + drift / projectionYears
        let pace = min(maxPace, max(minPace, rawPace))

        let deltas = monthlyWindows.compactMap {
            VitalityEngine.compute($0.restricted(to: common))?.unclampedBodyAge
        }
        let measured = deltas.count >= minWindowsForSpread
        let sd: Double
        if measured {
            let mean = deltas.reduce(0, +) / Double(deltas.count)
            let variance = deltas.reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / Double(deltas.count - 1)
            sd = max(minWindowSD, variance.squareRoot())
        } else {
            sd = priorWindowSD
        }
        let margin = steadyZ * sd / projectionYears
        return Projection(pace: pace, currentBodyAge: current.bodyAge,
                          projectedBodyAge: current.bodyAge + projectionYears * pace,
                          paceMargin: margin, isSteady: abs(rawPace - 1) < margin,
                          lowerConfidence: !measured, comparedKeys: common.sorted())
    }

    // MARK: - Shared constants

    /// Fewest scored DAYS a 30-day window must hold before it counts as one month of habits. Near the
    /// start of someone's history the same span holds two or three days, and a Body Age computed from
    /// them is a far noisier quantity than one from thirty — same units, same name, different thing.
    public static let minWindowDays = 15
    /// WHOOP presents Pace of Aging on a −1× … 3× scale; the clamp keeps an extreme month on it.
    public static let minPace = -1.0, maxPace = 3.0
    /// Two-sided 95 % normal critical value.
    static let steadyZ = 1.96

    /// Day index for a "yyyy-MM-dd" key: whole days since 1970-01-01, counted on a fixed UTC calendar.
    ///
    /// UTC deliberately, and it is not a bug that the day keys themselves are LOCAL days. The index is
    /// only ever used for DIFFERENCES between two day keys, and counting those on a fixed calendar is what
    /// makes a DST weekend six days wide instead of five-and-a-fraction. Nil for an unparseable key.
    public static func dayIndex(_ day: String) -> Int? {
        let parts = day.split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count == 3,
              let y = Int(parts[0]), let m = Int(parts[1]), let d = Int(parts[2]),
              (1...12).contains(m), (1...31).contains(d) else { return nil }
        var comps = DateComponents()
        comps.year = y; comps.month = m; comps.day = d
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        guard let date = cal.date(from: comps) else { return nil }
        return Int((date.timeIntervalSince1970 / 86_400).rounded())
    }
}
