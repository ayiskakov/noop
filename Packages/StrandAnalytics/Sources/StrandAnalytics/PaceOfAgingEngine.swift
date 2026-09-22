import Foundation

// PaceOfAgingEngine.swift — "is my Body Age heading up or down, and how fast?", in × per year.
//
// INDEPENDENT implementation of the idea WHOOP presents as "Pace of Aging" (NOT medical advice; a trend
// in a wellness estimate, never a clinical rate of biological aging). It is not a second model: it falls
// directly out of the one `VitalityEngine` already computes.
//
//   Body Age = age + S/k            (S = the shrunk summed log-hazard, k = ln2/8 per year — Gompertz)
//   d(Body Age)/dt = 1 + (dS/dt)/k
//
// So the pace of aging is literally 1 plus the drift of your own summed log-hazard, rescaled by the same
// constant the Body Age uses. Nothing new is assumed and nothing is calibrated by hand: a person whose
// behaviour holds steady has dS/dt = 0 and ages at exactly 1× by construction.
//
// dS/dt is estimated by ordinary least squares over one rolling-30-day S per day across the last 90 days.
// The 30-day window is what makes a sample a habit rather than a night; the 90-day span is what makes the
// slope a trend rather than a mood.
//
// ── TWO WAYS THIS COULD LIE, AND WHAT STOPS THEM ──────────────────────────────────────────────────
//
//  1. A slope fitted to noise always has SOME sign, so a dial reading it would swing between "aging
//     faster" and "aging slower" on nothing. `isSteady` is therefore reported alongside the number: when
//     the slope is not distinguishable from zero at 95%, the honest readout is "holding steady", not a
//     figure. A pace is a promise about where you are heading; it is only made when there is a trend.
//
//  2. If the SET of factors feeding S changes mid-window — a user connects a step source, a lean-mass
//     reading arrives — S jumps for a reason that has nothing to do with how they lived, and the fit
//     reads that jump as aging. So every sample carries the signature of the factors behind it, and only
//     the newest contiguous run sharing the newest signature is ever fitted. A person who just added a
//     data source waits for the run to refill rather than being told they aged.
public enum PaceOfAgingEngine {

    /// Days of history rolled into ONE sample of S. A habit, not a night.
    public static let recentWindowDays = 30
    /// How far back the slope is fitted. Older samples than this are ignored even when present.
    public static let trendWindowDays = 90
    /// Fewest DAYS that must actually carry data inside one rolling window before it may become a sample.
    ///
    /// A window is meant to be a habit. Near the start of someone's history the same 30-day span holds two
    /// or three days, and the S computed from it is a far noisier quantity than the S computed from thirty
    /// — same units, same name, different thing. Fitting a trend through both reads the ordinary spread of
    /// the thin end as a direction. Callers assembling samples enforce this; `usableSamples` cannot, since
    /// a sample arrives already reduced to one number.
    public static let minWindowDays = 15
    /// Fewest usable samples before a pace is reported at all.
    public static let minSamples = 60
    /// WHOOP presents the same idea on a −1× … 3× scale; the clamp keeps a sparse or extreme fit on it.
    public static let minPace = -1.0, maxPace = 3.0
    /// Days per year used to annualise a per-day slope.
    static let daysPerYear = 365.25
    /// Two-sided 95% normal critical value — the bar a slope clears before it is called a direction.
    static let steadyZ = 1.96

    /// One day's rolling-30-day summed log-hazard, as `VitalityEngine.Result.lnHazardSum` reports it.
    public struct Sample: Equatable, Sendable {
        /// Days since any fixed epoch — only differences between samples matter.
        public let dayIndex: Int
        public let lnHazardSum: Double
        /// The factors behind this sample, sorted and joined (e.g. "hrv,rhr,sleep,steps"). Samples whose
        /// signature differs from the newest one are not comparable and are not fitted. See the header.
        public let factorSignature: String

        public init(dayIndex: Int, lnHazardSum: Double, factorSignature: String) {
            self.dayIndex = dayIndex; self.lnHazardSum = lnHazardSum
            self.factorSignature = factorSignature
        }
    }

    public struct Result: Equatable, Sendable {
        /// Body Age years gained per calendar year, clamped to [minPace, maxPace]. 1 = holding steady.
        public let pace: Double
        /// Drift of the summed log-hazard, per year — the raw fitted slope before rescaling.
        public let slopeLnPerYear: Double
        /// Standard error of that slope, same units.
        public let standardErrorLnPerYear: Double
        /// ± band on `pace` at 95%, in the same × units, so a UI can show the number with its uncertainty.
        public let paceMargin: Double
        /// True when the slope is not distinguishable from zero at 95% — show "holding steady", not a figure.
        public let isSteady: Bool
        public let samplesUsed: Int
        /// True when fewer than `trendWindowDays` samples were available, so the fit rests on a short span.
        public let lowerConfidence: Bool

        public init(pace: Double, slopeLnPerYear: Double, standardErrorLnPerYear: Double,
                    paceMargin: Double, isSteady: Bool, samplesUsed: Int, lowerConfidence: Bool) {
            self.pace = pace; self.slopeLnPerYear = slopeLnPerYear
            self.standardErrorLnPerYear = standardErrorLnPerYear; self.paceMargin = paceMargin
            self.isSteady = isSteady; self.samplesUsed = samplesUsed
            self.lowerConfidence = lowerConfidence
        }
    }

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

    /// The samples a fit would actually use: the newest `trendWindowDays` days, restricted to the newest
    /// contiguous run whose factor signature matches the newest sample's. Exposed so the readiness
    /// countdown and the fit can never disagree about what counts.
    public static func usableSamples(_ samples: [Sample]) -> [Sample] {
        let sorted = samples.sorted { $0.dayIndex < $1.dayIndex }
        guard let newest = sorted.last else { return [] }
        var run: [Sample] = []
        for s in sorted.reversed() {
            guard s.factorSignature == newest.factorSignature else { break }
            guard newest.dayIndex - s.dayIndex < trendWindowDays else { break }
            run.append(s)
        }
        return run.reversed()
    }

    /// Samples still needed before a pace can be reported at all — the countdown a not-ready card shows.
    /// Assumes continued daily wear; a gap simply doesn't advance the count.
    public static func daysUntilReady(_ samples: [Sample]) -> Int {
        max(0, minSamples - usableSamples(samples).count)
    }

    /// Fit the pace of aging. Nil until `minSamples` comparable samples exist, or when every sample falls
    /// on one day (no time base to fit a slope against).
    public static func compute(samples: [Sample]) -> Result? {
        let used = usableSamples(samples)
        guard used.count >= minSamples else { return nil }

        let n = Double(used.count)
        let xs = used.map { Double($0.dayIndex) }
        let ys = used.map { $0.lnHazardSum }
        let meanX = xs.reduce(0, +) / n
        let meanY = ys.reduce(0, +) / n
        var sxx = 0.0, sxy = 0.0
        for i in 0..<used.count {
            let dx = xs[i] - meanX
            sxx += dx * dx
            sxy += dx * (ys[i] - meanY)
        }
        guard sxx > 0 else { return nil }              // every sample on one day

        let slopePerDay = sxy / sxx
        let intercept = meanY - slopePerDay * meanX
        // Residual standard error of the slope: sqrt( SSE/(n−2) / Sxx ).
        var sse = 0.0
        for i in 0..<used.count {
            let fitted = intercept + slopePerDay * xs[i]
            sse += (ys[i] - fitted) * (ys[i] - fitted)
        }
        let slopeSEPerDay = ((sse / (n - 2)) / sxx).squareRoot()

        let slopePerYear = slopePerDay * daysPerYear
        let sePerYear = slopeSEPerDay * daysPerYear
        let rawPace = 1 + slopePerYear / VitalityEngine.lnHazardPerYear
        let margin = steadyZ * sePerYear / VitalityEngine.lnHazardPerYear
        return Result(pace: min(maxPace, max(minPace, rawPace)),
                      slopeLnPerYear: slopePerYear,
                      standardErrorLnPerYear: sePerYear,
                      paceMargin: margin,
                      isSteady: abs(slopePerYear) < steadyZ * sePerYear,
                      samplesUsed: used.count,
                      lowerConfidence: used.count < trendWindowDays)
    }
}
