import Foundation

// ResilienceEngine.swift — "how quickly does my body settle back after it is knocked off its normal state?"
//
// EXPERIMENTAL. An independent implementation of the recovery-time idea in Pyrkov et al., Nat Commun 2021
// (doi 10.1038/s41467-021-23014-1). NOT medical advice, and not validated for one person: the published
// recovery time is a COHORT quantity, fitted to autocorrelation functions averaged over age-matched groups.
// Nothing reads this engine's output into another score (AGENTS.md, deriving physiological signals).
//
// ── THE MODEL ─────────────────────────────────────────────────────────────────────────────────────
//
// The day-to-day fluctuation δx of a state indicator is treated as a Langevin (Ornstein–Uhlenbeck)
// process, dδx/dt = −ε·δx + f(t). Its autocorrelation decays as C(Δt) ~ exp(−ε·Δt), and τ = 1/ε is the
// recovery time: how many days a disturbance takes to fade by a factor e. Pyrkov reports τ lengthening
// with age (about two weeks at 40, beyond eight weeks at 90) in blood counts, and the same decline in the
// recovery rate of log daily step counts from wristband wearers. Log steps is the published signal;
// resting HR and ln(RMSSD) are NOOP extensions of the same method.
//
// ── THE PIPELINE (`analyze`) ──────────────────────────────────────────────────────────────────────
//
// 1. Signal: ln(steps), resting HR, or ln(RMSSD), one value per day. A day with no reading is MISSING,
//    never zero.
// 2. Window: the trailing `windowDays`, which must hold `minObservedDays` observed days.
// 3. Structure that is not recovery dynamics is removed jointly: a per-weekday mean (steps are strongly
//    weekly) and one linear trend (a slow drift would otherwise read as a long τ). The trend slope is the
//    exact joint least-squares fit, via Frisch–Waugh: demean both day and value within each weekday, then
//    regress.
// 4. Autocorrelation C(k), k = 1…`maxLag`, over the pairs of observed days k apart.
// 5. Fit C(k) = A·exp(−k/τ), weighted by each lag's pair count. The free amplitude A ≤ 1 absorbs
//    day-level noise that has no memory (a "nugget"). τ is bounded to [`tauFloor`, `tauCeiling`]. When A
//    stays under `minAmplitude` the series has no measurable memory and τ sits at the floor.
// 6. A short autocorrelation misreads τ (a 180-day window with a trend removed cannot hold a long
//    process whole), and one person's τ̂ is noisy. Both are handled by inverting a seeded parametric
//    bootstrap: for each τ on a log grid, the fitted process is simulated over the SAME observed days
//    and run through the SAME pipeline, giving the τ̂ that τ would produce. The estimate is the τ whose
//    median τ̂ matches the measured one; the 90 % interval is every τ whose central 90 % of τ̂ covers it.
//    On synthetic series with τ = 7, 14, 28 and 56 days, weekly structure, noise and 20 % missing days,
//    the interval covers the truth in 85–92 % of seeds (ResilienceEngineTests). It is wide: that is what
//    one person's half-year can say.
// 7. σ, the SD of the de-structured series in the signal's own units, is Pyrkov's second hallmark
//    (the fluctuation variance also rises with age).
//
// ── KNOCKS (`knocks`) ─────────────────────────────────────────────────────────────────────────────
//
// A knock is a day at least `knockThreshold` robust SDs from its rolling baseline: the median of the
// `knockBaselineDays` before it, after the weekday pattern is removed, frozen at the knock's start so the
// return is measured against the state before it. Its peak is the most extreme same-direction day within
// `knockPeakSearchDays`, and the day after the peak must still sit outside the baseline band, so a lone
// outlier day is not a knock. From the peak the path back is followed for `knockHorizonDays`. The
// observed return is the first day back within `baselineBand` SDs, and the half-life comes from fitting
// P·exp(−t/τₖ) to the path. That is concrete, per-event evidence of the same quantity the autocorrelation
// measures on average.
public enum ResilienceEngine {

    // MARK: - Constants

    /// Trailing window each estimate reads, days.
    public static let windowDays = 180
    /// Observed days the window must hold before τ is estimated.
    public static let minObservedDays = 90
    /// Longest lag in the autocorrelation, days.
    public static let maxLag = 28
    /// Bounds on τ, days.
    public static let tauFloor = 1.0
    public static let tauCeiling = 180.0
    /// Bootstrap replicates per candidate τ behind the bias correction and the interval.
    public static let defaultReplicates = 100
    /// Candidate τ values, log-spaced over [tauFloor, tauCeiling], the bootstrap is inverted over.
    public static let calibrationGridPoints = 16
    /// Fixed seed, so the same history always gives the same interval.
    public static let bootstrapSeed: UInt64 = 0x5EED_2021
    /// Interval quantiles (a 90 % interval).
    public static let intervalLow = 0.05
    public static let intervalHigh = 0.95

    /// Smallest fitted amplitude A that counts as memory. White noise over a 180-day window fits A of a
    /// few hundredths at most; below this the series is read as memoryless (τ at the floor, the interval
    /// the whole range) rather than as a faint, arbitrarily long process.
    public static let minAmplitude = 0.1

    /// Robust SDs from baseline that make a day a knock.
    public static let knockThreshold = 2.0
    /// Days after a knock starts within which its peak is sought.
    public static let knockPeakSearchDays = 3
    /// Days after the peak the return path is followed.
    public static let knockHorizonDays = 21
    /// Robust SDs within which a day counts as back at baseline.
    public static let baselineBand = 1.0
    /// Observed days a series needs before knocks are sought (the baseline has to mean something).
    public static let minKnockDays = 28
    /// Days before a knock its baseline (a median) is read from, and the observed days it needs.
    public static let knockBaselineDays = 28
    public static let knockBaselineMinDays = 14
    /// Post-peak observed days a half-life fit needs.
    public static let minKnockFitPoints = 3
    /// Share of a knock's path its fitted return must explain before a half-life is reported.
    public static let minKnockFitExplained = 0.5
    /// Days an estimate of a knock's decay constant is bounded to.
    public static let knockTauFloor = 0.25
    public static let knockTauCeiling = 60.0

    // MARK: - Types

    public enum Signal: String, CaseIterable, Sendable {
        /// ln(daily steps): the signal Pyrkov et al. published.
        case steps
        /// Nightly resting heart rate, bpm: a NOOP extension.
        case restingHR
        /// ln(nightly RMSSD): a NOOP extension.
        case hrv

        /// True only for the signal the published method used.
        public var isPublished: Bool { self == .steps }

        /// The analysed value for one day's raw reading, or nil when the day counts as missing.
        public func transform(_ raw: Double) -> Double? {
            guard raw.isFinite else { return nil }
            switch self {
            case .steps:     return raw >= ResilienceEngine.minimumSteps ? Foundation.log(raw) : nil
            case .restingHR: return raw > 0 ? raw : nil
            case .hrv:       return raw > 0 ? Foundation.log(raw) : nil
            }
        }
    }

    /// A step total below this is an unworn day, not a still one.
    public static let minimumSteps = 100.0

    /// One day's raw reading. `dayIndex` counts days from any fixed epoch (`PaceOfAgingEngine.dayIndex`);
    /// weekdays are taken as `dayIndex mod 7`, which only needs to be consistent.
    public struct DayValue: Equatable, Sendable {
        public let dayIndex: Int
        public let value: Double
        public init(dayIndex: Int, value: Double) {
            self.dayIndex = dayIndex
            self.value = value
        }
    }

    public struct Estimate: Equatable, Sendable {
        /// Bias-corrected recovery time, days. The headline.
        public let tau: Double
        /// 90 % interval on `tau`, days.
        public let tauLow: Double
        public let tauHigh: Double
        /// τ fitted to the measured autocorrelation before the bias correction: the curve drawn over the
        /// points in `acf`.
        public let tauFit: Double
        /// Fitted amplitude A of A·exp(−k/τ); 1 − A is the memoryless share of the day-to-day variance.
        public let amplitude: Double
        /// SD of the de-structured series, in the analysed units (ln units for steps and HRV, bpm for RHR).
        public let sigma: Double
        /// Measured C(k) for k = 1…maxLag (`acf[k - 1]`); nil where no pair of observed days is k apart.
        public let acf: [Double?]
        /// Pairs of observed days behind each `acf` entry.
        public let acfPairs: [Int]

        public init(tau: Double, tauLow: Double, tauHigh: Double, tauFit: Double, amplitude: Double,
                    sigma: Double, acf: [Double?], acfPairs: [Int]) {
            self.tau = tau
            self.tauLow = tauLow
            self.tauHigh = tauHigh
            self.tauFit = tauFit
            self.amplitude = amplitude
            self.sigma = sigma
            self.acf = acf
            self.acfPairs = acfPairs
        }

        /// False when the fitted amplitude is under `minAmplitude`: no measurable memory, so `tau` sits at
        /// the floor and says nothing about recovery.
        public var hasMemory: Bool { amplitude >= ResilienceEngine.minAmplitude }

        /// The fitted curve A·exp(−k/τ) at lag `k`, for any τ (the fit, or an interval bound).
        public func fitted(atLag k: Double, tau: Double? = nil) -> Double {
            amplitude * Foundation.exp(-k / (tau ?? tauFit))
        }
    }

    public struct Result: Equatable, Sendable {
        public let signal: Signal
        /// Last day of the window.
        public let endDay: Int
        /// Observed days in the window.
        public let observedDays: Int
        /// More observed days needed before an estimate exists; 0 once `estimate` is set.
        public let daysUntilReady: Int
        /// Nil while the window is still collecting.
        public let estimate: Estimate?

        public init(signal: Signal, endDay: Int, observedDays: Int, daysUntilReady: Int, estimate: Estimate?) {
            self.signal = signal
            self.endDay = endDay
            self.observedDays = observedDays
            self.daysUntilReady = daysUntilReady
            self.estimate = estimate
        }
    }

    public struct Knock: Equatable, Sendable {
        /// First day at least `knockThreshold` SDs from baseline.
        public let startDay: Int
        /// Most extreme same-direction day within `knockPeakSearchDays` of the start.
        public let peakDay: Int
        /// Peak deviation in robust SDs; negative when the day fell below baseline.
        public let peakDeviation: Double
        /// Deviation in robust SDs, sign-aligned so the peak is positive, for each observed day from the
        /// peak to `knockHorizonDays` after it (`dayIndex` counts days since the peak).
        public let path: [DayValue]
        /// Observed days from the peak to the first day back within `baselineBand`; nil if not yet back.
        public let daysToBaseline: Int?
        /// Half-life of the fitted return P·exp(−t/τₖ), days; nil with too few points to fit, or when the
        /// fit does not describe the path (height inside the baseline band, τₖ on a search bound, or
        /// under `minKnockFitExplained` of the path explained).
        public let halfLifeDays: Double?
        /// Fitted height P of the return curve, in the path's sign-aligned units; nil with no fit.
        public let returnAmplitude: Double?

        /// The fitted return curve at `t` days after the peak, in the path's sign-aligned units.
        public func fittedReturn(atDay t: Double) -> Double? {
            guard let h = halfLifeDays, let p = returnAmplitude else { return nil }
            return p * Foundation.exp(-t * Foundation.log(2) / h)
        }
    }

    // MARK: - Analysis

    /// Recovery time of `signal` over the `windowDays` ending at `endDay` (default: the newest day in
    /// `series`). Nil when the window holds no usable day at all.
    public static func analyze(series: [DayValue], signal: Signal, endDay: Int? = nil,
                               replicates: Int = defaultReplicates) -> Result? {
        guard let end = endDay ?? series.map(\.dayIndex).max() else { return nil }
        let window = observed(series, signal: signal, endDay: end)
        guard !window.isEmpty else { return nil }
        let n = window.count
        guard n >= minObservedDays else {
            return Result(signal: signal, endDay: end, observedDays: n,
                          daysUntilReady: minObservedDays - n, estimate: nil)
        }
        let pipeline = Pipeline(days: window.map(\.dayIndex))
        let measured = pipeline.run(window.map(\.value))
        let (tau, low, high) = calibrate(pipeline, tauFit: measured.tau, amplitude: measured.amplitude,
                                         replicates: replicates)
        let acf = (0..<maxLag).map { pipeline.pairs[$0] > 0 ? measured.acf[$0] : nil }
        let estimate = Estimate(tau: tau, tauLow: low, tauHigh: high, tauFit: measured.tau,
                                amplitude: measured.amplitude, sigma: measured.sigma, acf: acf,
                                acfPairs: pipeline.pairs)
        return Result(signal: signal, endDay: end, observedDays: n, daysUntilReady: 0, estimate: estimate)
    }

    /// One `analyze` per end day: the rolling readout behind the τ and σ trend.
    public static func trend(series: [DayValue], signal: Signal, endDays: [Int],
                             replicates: Int = defaultReplicates) -> [Result] {
        endDays.compactMap { analyze(series: series, signal: signal, endDay: $0, replicates: replicates) }
    }

    /// Knocks in the `windowDays` ending at `endDay` (default: the newest day), oldest first.
    public static func knocks(series: [DayValue], signal: Signal, endDay: Int? = nil) -> [Knock] {
        guard let end = endDay ?? series.map(\.dayIndex).max() else { return [] }
        // The window, plus the stretch before it that the first days' baselines are read from.
        let window = observed(series, signal: signal, endDay: end, span: windowDays + knockBaselineDays)
        guard window.count >= minKnockDays else { return [] }
        let days = window.map(\.dayIndex)
        let values = Pipeline(days: days).removeWeekdayMeans(window.map(\.value))

        // Each day's baseline: the median of the observed days in the `knockBaselineDays` before it.
        var baseline = [Double?](repeating: nil, count: days.count)
        var lower = 0
        for i in days.indices {
            while days[lower] < days[i] - knockBaselineDays { lower += 1 }
            let prior = values[lower..<i]
            if prior.count >= knockBaselineMinDays { baseline[i] = quantile(prior.sorted(), 0.5) }
        }
        // One scale for the whole window: the robust spread of each day around its own baseline.
        let deviations = days.indices.compactMap { i in baseline[i].map { values[i] - $0 } }
        guard deviations.count >= minKnockDays else { return [] }
        let scale = robustSD(deviations)
        guard scale > flatTolerance else { return [] }

        let firstDay = end - windowDays + 1
        var knocks: [Knock] = []
        var i = days.firstIndex { $0 >= firstDay } ?? days.count
        while i < days.count {
            guard let base = baseline[i], abs(values[i] - base) / scale >= knockThreshold else { i += 1; continue }
            // The baseline is frozen at the knock's start, so the return is measured against the state
            // before it, not against a median the knock itself is dragging along.
            let sign: Double = values[i] > base ? 1 : -1
            let z = { (k: Int) in sign * (values[k] - base) / scale }
            var peak = i
            var j = i + 1
            while j < days.count, days[j] - days[i] <= knockPeakSearchDays {
                if z(j) > z(peak) { peak = j }
                j += 1
            }
            // A lone outlier day is noise, not a knock: the next observed day must still be outside the
            // baseline band in the same direction.
            guard peak + 1 < days.count, days[peak + 1] - days[peak] <= knockPeakSearchDays,
                  z(peak + 1) >= baselineBand else { i += 1; continue }
            var path: [DayValue] = []
            var back: Int?
            var k = peak
            while k < days.count, days[k] - days[peak] <= knockHorizonDays {
                let t = days[k] - days[peak]
                path.append(DayValue(dayIndex: t, value: z(k)))
                if back == nil, k > peak, z(k) < baselineBand { back = t }
                k += 1
            }
            // Only a fit that describes the path is timed: its height must be outside the band, its
            // decay constant off the search bounds, and the curve must explain most of the path. A flat
            // fit pinned at the ceiling would otherwise print a weeks-long half-life beside a return
            // observed in two days.
            let decay = path.count - 1 >= minKnockFitPoints ? fitReturn(path) : nil
            let timed = decay.flatMap { d in
                d.amplitude >= baselineBand && d.explained >= minKnockFitExplained
                    && d.tau < knockTauCeiling * 0.99 && d.tau > knockTauFloor * 1.01 ? d : nil
            }
            knocks.append(Knock(startDay: days[i], peakDay: days[peak], peakDeviation: sign * z(peak),
                                path: path, daysToBaseline: back,
                                halfLifeDays: timed.map { $0.tau * Foundation.log(2) },
                                returnAmplitude: timed?.amplitude))
            // The next knock can only start once this one is back at baseline (or out of view).
            if let back {
                i = (days.firstIndex { $0 >= days[peak] + back } ?? days.count - 1) + 1
            } else {
                i = k
            }
        }
        return knocks
    }

    // MARK: - Pipeline (internal for tests)

    /// A residual SD below this (in the analysed units) is a flat series: nothing to correlate.
    static let flatTolerance = 1e-9

    /// Everything that depends only on WHICH days were observed, computed once and shared by the measured
    /// series and every bootstrap replicate, so both go through exactly the same steps.
    struct Pipeline {
        let count: Int
        /// Offset of each observed day from the first.
        let offsets: [Int]
        /// Days from the first observed day to the last, inclusive.
        let span: Int
        /// Weekday group of each observed day, and each group's size.
        let group: [Int]
        let groupCount: [Double]
        /// Day number demeaned within its weekday group (the Frisch–Waugh regressor), and Σ of its square.
        let centredDay: [Double]
        let centredDaySS: Double
        /// Pairs of observed days k apart, k = 1…maxLag.
        let pairs: [Int]

        init(days: [Int]) {
            count = days.count
            let first = days.first ?? 0
            offsets = days.map { $0 - first }
            span = (offsets.last ?? -1) + 1
            group = days.map(ResilienceEngine.weekday)
            var groupCount = [Double](repeating: 0, count: 7), dayTotal = groupCount
            for (g, d) in zip(group, days) { groupCount[g] += 1; dayTotal[g] += Double(d) }
            self.groupCount = groupCount
            let centred = zip(group, days).map { Double($1) - dayTotal[$0] / groupCount[$0] }
            centredDay = centred
            centredDaySS = centred.reduce(0) { $0 + $1 * $1 }
            var mask = [Bool](repeating: false, count: span)
            for o in offsets { mask[o] = true }
            pairs = (1...maxLag).map { k in
                k < mask.count ? (0..<(mask.count - k)).reduce(0) { $0 + (mask[$1] && mask[$1 + k] ? 1 : 0) } : 0
            }
        }

        /// Values less their weekday's mean (no trend removed): what knocks are measured on.
        func removeWeekdayMeans(_ values: [Double]) -> [Double] {
            var total = [Double](repeating: 0, count: 7)
            for i in 0..<count { total[group[i]] += values[i] }
            return (0..<count).map { values[$0] - total[group[$0]] / groupCount[group[$0]] }
        }

        /// Residuals after removing per-weekday means and one linear trend, fitted jointly.
        func destructure(_ values: [Double]) -> [Double] {
            var total = [Double](repeating: 0, count: 7)
            for i in 0..<count { total[group[i]] += values[i] }
            var demeaned = [Double](repeating: 0, count: count)
            var sxy = 0.0
            for i in 0..<count {
                demeaned[i] = values[i] - total[group[i]] / groupCount[group[i]]
                sxy += centredDay[i] * demeaned[i]
            }
            let slope = centredDaySS > 0 ? sxy / centredDaySS : 0
            for i in 0..<count { demeaned[i] -= slope * centredDay[i] }
            return demeaned
        }

        /// C(k), k = 1…maxLag, over pairs of observed days k apart, normalised by the lag-0 variance. A
        /// lag with no pair reads 0 and carries no weight in the fit.
        func autocorrelation(_ residual: [Double]) -> (acf: [Double], variance: Double) {
            var dense = [Double](repeating: 0, count: span)
            var variance = 0.0
            for i in 0..<count {
                dense[offsets[i]] = residual[i]
                variance += residual[i] * residual[i]
            }
            variance /= Double(max(count, 1))
            var acf = [Double](repeating: 0, count: maxLag)
            guard variance > 0 else { return (acf, 0) }
            dense.withUnsafeBufferPointer { d in
                for k in 1...maxLag where pairs[k - 1] > 0 {
                    var sum = 0.0
                    for i in 0..<(span - k) { sum += d[i] * d[i + k] }
                    acf[k - 1] = sum / Double(pairs[k - 1]) / variance
                }
            }
            return (acf, variance)
        }

        /// De-structure, correlate and fit one series.
        func run(_ values: [Double]) -> (tau: Double, amplitude: Double, sigma: Double, acf: [Double]) {
            let residual = destructure(values)
            let sigma = ResilienceEngine.sd(residual)
            guard sigma > flatTolerance else {
                return (tauFloor, 0, sigma, [Double](repeating: 0, count: maxLag))
            }
            let (acf, _) = autocorrelation(residual)
            let (tau, amplitude) = ResilienceEngine.fit(acf: acf, pairs: pairs)
            return (tau, amplitude, sigma, acf)
        }
    }

    /// Bias correction and interval by inverting a seeded parametric bootstrap. For each candidate τ on a
    /// log grid, the fitted process is simulated `replicates` times over the same observed days with
    /// common random numbers and run through the same pipeline, giving the distribution of fitted ln τ̂
    /// that τ produces. The estimate is the τ whose median ln τ̂ equals the one measured; the interval
    /// holds every τ whose central 90 % of ln τ̂ covers it. Both are interpolated in ln τ.
    static func calibrate(_ pipeline: Pipeline, tauFit: Double, amplitude: Double,
                          replicates: Int) -> (tau: Double, low: Double, high: Double) {
        guard amplitude >= minAmplitude, replicates > 0 else { return (tauFloor, tauFloor, tauCeiling) }
        let lo = Foundation.log(tauFloor), hi = Foundation.log(tauCeiling)
        let grid = (0..<calibrationGridPoints).map {
            lo + (hi - lo) * Double($0) / Double(calibrationGridPoints - 1)
        }
        var median: [Double] = [], qLow: [Double] = [], qHigh: [Double] = []
        for logTau in grid {
            // A long true τ also depresses the FITTED amplitude (the trend removal eats part of a slow
            // process), so a first, smaller pass scales the simulated amplitude until its median fit
            // matches the one measured. Otherwise a long τ is tested at a weaker signal than the history
            // showed, and nothing could ever rule it out.
            var trueAmplitude = amplitude
            let probe = simulateFits(pipeline, tau: Foundation.exp(logTau), amplitude: trueAmplitude,
                                     replicates: max(1, replicates / 4))
            let probeMedian = quantile(probe.amplitudes.sorted(), 0.5)
            if probeMedian > 0 { trueAmplitude = min(1, trueAmplitude * amplitude / probeMedian) }
            let fitted = simulateFits(pipeline, tau: Foundation.exp(logTau), amplitude: trueAmplitude,
                                      replicates: replicates).logTaus.sorted()
            median.append(quantile(fitted, 0.5))
            qLow.append(quantile(fitted, intervalLow))
            qHigh.append(quantile(fitted, intervalHigh))
        }
        let measured = Foundation.log(tauFit)
        let tau = crossing(grid: grid, curve: median, level: measured, fromLow: true)
        // Lower bound: the smallest τ whose upper quantile reaches the measurement; upper bound: the
        // largest τ whose lower quantile has not passed it.
        let low = crossing(grid: grid, curve: qHigh, level: measured, fromLow: true)
        let high = crossing(grid: grid, curve: qLow, level: measured, fromLow: false)
        let clampTau = { (x: Double) in min(tauCeiling, max(tauFloor, Foundation.exp(x))) }
        return (clampTau(tau), clampTau(min(low, tau)), clampTau(max(high, tau)))
    }

    /// Fitted ln τ̂ and amplitude of `replicates` simulated series (seeded, so every candidate τ sees the
    /// same random numbers).
    static func simulateFits(_ pipeline: Pipeline, tau: Double, amplitude: Double,
                             replicates: Int) -> (logTaus: [Double], amplitudes: [Double]) {
        var rng = SplitMix64(seed: bootstrapSeed)
        var logTaus: [Double] = [], amplitudes: [Double] = []
        logTaus.reserveCapacity(replicates)
        amplitudes.reserveCapacity(replicates)
        for _ in 0..<replicates {
            let r = pipeline.run(simulate(pipeline, tau: tau, amplitude: amplitude, rng: &rng))
            logTaus.append(Foundation.log(r.tau))
            amplitudes.append(r.amplitude)
        }
        return (logTaus, amplitudes)
    }

    /// Where a (roughly increasing) curve over the grid meets `level`, interpolated. Scanning from the low
    /// end gives the first crossing, from the high end the last; a level beyond the curve gives that end.
    static func crossing(grid: [Double], curve: [Double], level: Double, fromLow: Bool) -> Double {
        let n = grid.count
        if fromLow {
            if curve[0] >= level { return grid[0] }
            for i in 1..<n where curve[i] >= level {
                let f = (level - curve[i - 1]) / (curve[i] - curve[i - 1])
                return grid[i - 1] + f * (grid[i] - grid[i - 1])
            }
            return grid[n - 1]
        } else {
            if curve[n - 1] <= level { return grid[n - 1] }
            for i in stride(from: n - 2, through: 0, by: -1) where curve[i] <= level {
                let f = (level - curve[i]) / (curve[i + 1] - curve[i])
                return grid[i] + f * (grid[i + 1] - grid[i])
            }
            return grid[0]
        }
    }

    /// Transformed readings for the `span` days ending at `endDay`, one per day, oldest first.
    /// A day given twice keeps its last reading.
    static func observed(_ series: [DayValue], signal: Signal, endDay: Int,
                         span: Int = windowDays) -> [DayValue] {
        let start = endDay - span + 1
        var byDay: [Int: Double] = [:]
        for p in series where p.dayIndex >= start && p.dayIndex <= endDay {
            if let v = signal.transform(p.value) { byDay[p.dayIndex] = v }
        }
        return byDay.keys.sorted().map { DayValue(dayIndex: $0, value: byDay[$0]!) }
    }

    /// Weighted least-squares fit of A·exp(−k/τ): a log-spaced grid over [tauFloor, tauCeiling], refined
    /// by the vertex of the parabola through the best grid point and its neighbours. A is solved in closed
    /// form per τ and held to [0, 1]. When the best A is under `minAmplitude` the series has no
    /// measurable memory and τ is the floor.
    static func fit(acf: [Double], pairs: [Int]) -> (tau: Double, amplitude: Double) {
        // Per lag: weight w, and w·c; Σw·c² is the same for every τ.
        var w = [Double](repeating: 0, count: maxLag), wc = w
        var scc = 0.0
        for i in 0..<maxLag {
            w[i] = Double(pairs[i])
            wc[i] = w[i] * acf[i]
            scc += wc[i] * acf[i]
        }
        let rows = fitGrid.count
        var sse = [Double](repeating: 0, count: rows), amp = sse
        // Σw(c − A·e)² expanded, with A = Σwce / Σwe² held to [0, 1]: one pass over each row.
        w.withUnsafeBufferPointer { w in
            wc.withUnsafeBufferPointer { wc in
                fitGridCurves.withUnsafeBufferPointer { table in
                    for g in 0..<rows {
                        var sce = 0.0, see = 0.0
                        let base = g * maxLag
                        for i in 0..<maxLag {
                            let e = table[base + i]
                            sce += wc[i] * e
                            see += w[i] * e * e
                        }
                        let a = see > 0 ? min(1, max(0, sce / see)) : 0
                        amp[g] = a
                        sse[g] = scc - 2 * a * sce + a * a * see
                    }
                }
            }
        }
        var best = 0
        for g in 1..<rows where sse[g] < sse[best] { best = g }
        var logTau = fitGrid[best], amplitude = amp[best]
        if best > 0, best < rows - 1 {
            let curvature = sse[best - 1] - 2 * sse[best] + sse[best + 1]
            if curvature > 0 {
                let step = fitGrid[best + 1] - fitGrid[best]
                let vertex = fitGrid[best] + 0.5 * step * (sse[best - 1] - sse[best + 1]) / curvature
                let rate = Foundation.exp(-vertex)
                var sce = 0.0, see = 0.0
                for i in 0..<maxLag {
                    let e = Foundation.exp(-Double(i + 1) * rate)
                    sce += wc[i] * e
                    see += w[i] * e * e
                }
                let a = see > 0 ? min(1, max(0, sce / see)) : 0
                if scc - 2 * a * sce + a * a * see <= sse[best] { logTau = vertex; amplitude = a }
            }
        }
        guard amplitude >= minAmplitude else { return (tauFloor, amplitude) }
        return (min(tauCeiling, max(tauFloor, Foundation.exp(logTau))), amplitude)
    }

    /// ln τ grid the fit scans, and exp(−k/τ) for k = 1…maxLag at each point (row-major), computed once.
    static let fitGrid: [Double] = {
        let lo = Foundation.log(tauFloor), hi = Foundation.log(tauCeiling), steps = 64
        return (0...steps).map { lo + (hi - lo) * Double($0) / Double(steps) }
    }()
    static let fitGridCurves: [Double] = fitGrid.flatMap { logTau in
        (1...maxLag).map { Foundation.exp(-Double($0) / Foundation.exp(logTau)) }
    }

    /// Least-squares P·exp(−t/τₖ) through a knock's sign-aligned path: τₖ by golden-section search in
    /// ln τₖ over [knockTauFloor, knockTauCeiling], P in closed form per τₖ; and the share of the path
    /// the curve explains.
    static func fitReturn(_ path: [DayValue]) -> (tau: Double, amplitude: Double, explained: Double) {
        func solve(_ logTau: Double) -> (sse: Double, p: Double) {
            let tau = Foundation.exp(logTau)
            var sze = 0.0, see = 0.0, szz = 0.0
            for point in path {
                let e = Foundation.exp(-Double(point.dayIndex) / tau)
                sze += point.value * e
                see += e * e
                szz += point.value * point.value
            }
            let p = see > 0 ? sze / see : 0
            return (szz - 2 * p * sze + p * p * see, p)
        }
        var a = Foundation.log(knockTauFloor), b = Foundation.log(knockTauCeiling)
        let g = (Foundation.sqrt(5) - 1) / 2
        var x1 = b - g * (b - a), x2 = a + g * (b - a)
        var f1 = solve(x1).sse, f2 = solve(x2).sse
        for _ in 0..<60 {
            if f1 < f2 { b = x2; x2 = x1; f2 = f1; x1 = b - g * (b - a); f1 = solve(x1).sse }
            else { a = x1; x1 = x2; f1 = f2; x2 = a + g * (b - a); f2 = solve(x2).sse }
        }
        let logTau = (a + b) / 2
        let best = solve(logTau)
        // Share of the path's (uncentred) sum of squares the curve accounts for; the model's baseline
        // is zero, so zero is the reference.
        let total = path.reduce(0) { $0 + $1.value * $1.value }
        return (Foundation.exp(logTau), best.p, total > 0 ? 1 - best.sse / total : 0)
    }

    /// An OU process with correlation time `tau` carrying share `amplitude` of the variance, plus
    /// memoryless noise for the rest, sampled on the pipeline's observed days.
    static func simulate(_ pipeline: Pipeline, tau: Double, amplitude: Double,
                         rng: inout SplitMix64) -> [Double] {
        let phi = Foundation.exp(-1 / tau), innovation = Foundation.sqrt(1 - phi * phi)
        let signal = Foundation.sqrt(amplitude), nugget = Foundation.sqrt(1 - amplitude)
        var out = [Double](repeating: 0, count: pipeline.count)
        var y = rng.nextGaussian()
        out.withUnsafeMutableBufferPointer { out in
            pipeline.offsets.withUnsafeBufferPointer { offsets in
                var next = 0
                for day in 0..<pipeline.span {
                    if day > 0 { y = phi * y + innovation * rng.nextGaussian() }
                    // Drawn on every day, observed or not, so the random stream is the same shape for
                    // any pattern of missing days.
                    let noise = rng.nextGaussian()
                    if next < offsets.count, offsets[next] == day {
                        out[next] = signal * y + nugget * noise
                        next += 1
                    }
                }
            }
        }
        return out
    }

    static func weekday(_ day: Int) -> Int { ((day % 7) + 7) % 7 }

    static func sd(_ x: [Double]) -> Double {
        guard x.count > 1 else { return 0 }
        let mean = x.reduce(0, +) / Double(x.count)
        return Foundation.sqrt(x.reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / Double(x.count - 1))
    }

    /// 1.4826 · median absolute deviation from the median; the plain SD when the MAD is zero.
    static func robustSD(_ x: [Double]) -> Double {
        guard !x.isEmpty else { return 0 }
        let median = quantile(x.sorted(), 0.5)
        let mad = quantile(x.map { abs($0 - median) }.sorted(), 0.5)
        return mad > 0 ? 1.4826 * mad : sd(x)
    }

    /// Linear-interpolated quantile of an ascending array.
    static func quantile(_ sorted: [Double], _ q: Double) -> Double {
        guard sorted.count > 1 else { return sorted.first ?? 0 }
        let h = q * Double(sorted.count - 1)
        let i = Int(h.rounded(.down)), f = h - Double(i)
        return i + 1 < sorted.count ? sorted[i] + f * (sorted[i + 1] - sorted[i]) : sorted[i]
    }

    /// SplitMix64 with Box–Muller normals: small, portable, and identical on every platform, so a seeded
    /// bootstrap gives the same interval everywhere.
    struct SplitMix64 {
        private var state: UInt64
        private var spare: Double?
        init(seed: UInt64) { state = seed }

        mutating func next() -> UInt64 {
            state &+= 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            return z ^ (z >> 31)
        }

        /// Uniform on (0, 1).
        mutating func nextUniform() -> Double { (Double(next() >> 11) + 0.5) / 9_007_199_254_740_992 }

        mutating func nextGaussian() -> Double {
            if let s = spare { spare = nil; return s }
            let u1 = nextUniform(), u2 = nextUniform()
            let r = Foundation.sqrt(-2 * Foundation.log(u1)), theta = 2 * Double.pi * u2
            spare = r * Foundation.sin(theta)
            return r * Foundation.cos(theta)
        }
    }
}
