import Foundation
import WhoopProtocol

/// Measured rhythm facts for one stored MG ECG recording (#891), for the review screen's
/// "Rhythm details" section.
///
/// EXPERIMENTAL, and deliberately NOT a classifier. Every field is a measurement over the beats
/// `EcgBeats` found: rates, how much of the recording sat above or below a fixed rate, and how much the
/// gaps between beats varied. Nothing here names a rhythm or a condition — no "sinus rhythm", no "AFib
/// not detected". A negative finding from an algorithm never validated against recordings of the
/// condition would be false reassurance, which is the costly direction; a chart of the intervals shows
/// irregularity to the reader without the app asserting what it means.
///
/// The strap's own classifier result is carried as its raw code. `docs/PROTOCOL_ECG.md` gives it no
/// established interpretation, so it is shown as a number and never mapped to a word.
public struct EcgRhythmFacts: Equatable, Sendable {

    /// Intervals in the window an interval's local rate is the median of: the five centred on it, the
    /// nearest five at a stretch's ends, or all of a shorter stretch. Five, so one missed or doubled
    /// beat moves a window's median by at most one position rather than setting its value.
    public static let rollingWindow = 5
    /// Intervals either side that form an interval's reference median for the artefact rule, which is
    /// `HRVAnalyzer`'s (an interval more than `HRVAnalyzer.ectopicThreshold` from that median is set
    /// aside as a likely missed or extra detection). Five rather than HRV's two: with two, a split beat
    /// (two short intervals) drags the median of its correct neighbours' windows down and sets them
    /// aside too.
    public static let neighbourReach = 5
    /// The fixed rates the high/low lines report against. Plain thresholds, not diagnoses.
    public static let highRate = 100.0
    public static let lowRate = 50.0

    /// Median rate over the recording.
    public let heartRate: Double
    /// 5th and 95th percentiles of the intervals' local rates: the range the rate moved through,
    /// without the single-window extremes an artefact produces. Widened where needed to take in
    /// `heartRate`: over a short or uneven series the median of every interval can fall outside the
    /// percentiles of the local rates ([889, 656, 805, 896, 905, 878, 746, 816] ms gave 70.8 bpm against
    /// 67.5–68.3), and a rate shown outside its own range contradicts itself.
    public let rateLow: Double
    public let rateHigh: Double
    /// Share of the analysed time (the usable intervals, summed) whose local rate was above `highRate`
    /// / below `lowRate`, 0…1. By time rather than by count: at a fast rate each interval is short, so a
    /// count overstates the time spent there (30 intervals of 400 ms then 10 of 1,000 ms are 75 % of the
    /// intervals but 55 % of the time).
    public let fractionAboveHigh: Double
    public let fractionBelowLow: Double
    /// Coefficient of variation of the kept intervals, in percent: the standard deviation within each
    /// stretch, pooled, over the mean. Pooled rather than taken over every interval at once, so a rate
    /// that differs between two stretches is not counted as variation.
    public let variationPercent: Double
    /// Root mean square of successive differences between kept intervals, in milliseconds. Only pairs
    /// of adjacent intervals in one stretch count: none across a stretch boundary, a rejected interval
    /// or a set-aside one.
    public let rmssdMs: Double?
    /// Intervals set aside by the artefact rule.
    public let setAsideIntervals: Int
    /// The strap's own classifier result code, from the first record where its classifier state
    /// reached 2 (observed when progress completes); nil when it never got there.
    public let strapResultCode: Int?

    /// Facts for a recording, or nil when `EcgBeats` found too few intervals for a rate.
    public static func from(_ beats: EcgBeats.Result, records: [EcgCandidateSample]) -> EcgRhythmFacts? {
        guard let rate = beats.heartRate else { return nil }
        // Every interval of each stretch, rejected ones included: the cleaner needs them in place to
        // know which of the kept ones were adjacent.
        let bySegment = Dictionary(grouping: beats.intervals, by: \.segment)
            .sorted { $0.key < $1.key }.map { $0.value.map(\.ms) }

        // One local rate per usable interval, with the interval's length as its weight in time.
        var local: [(bpm: Double, ms: Double)] = []
        var nn: [Double] = []
        var contiguous: [Bool] = []
        var pooledSquares = 0.0, pooledDegrees = 0
        var setAside = 0
        for raw in bySegment {
            let ms = raw.filter(EcgBeats.rrRangeMs.contains)
            if ms.isEmpty { continue }
            for i in ms.indices {
                let start = max(0, min(i - rollingWindow / 2, ms.count - rollingWindow))
                let window = Array(ms[start..<min(ms.count, start + rollingWindow)])
                local.append((60_000 / (EcgBeats.median(window) ?? ms[i]), ms[i]))
            }
            let clean = HRVAnalyzer.cleanRRGapAware(raw, radius: neighbourReach)
            setAside += ms.count - clean.nn.count
            // Each stretch's first kept interval is marked non-contiguous, so no difference is taken
            // across a stretch boundary when the stretches are appended.
            nn += clean.nn
            contiguous += clean.contiguous
            if let sd = HRVAnalyzer.sdnnRaw(clean.nn) {
                pooledSquares += sd * sd * Double(clean.nn.count - 1)
                pooledDegrees += clean.nn.count - 1
            }
        }

        let mean = nn.isEmpty ? 0 : nn.reduce(0, +) / Double(nn.count)
        let sd = pooledDegrees > 0 ? (pooledSquares / Double(pooledDegrees)).squareRoot() : 0
        let rmssd = HRVAnalyzer.rmssdGapAware(nn, contiguous)

        let rates = local.map(\.bpm)
        let analysedMs = local.reduce(0) { $0 + $1.ms }
        func shareOfTime(_ include: (Double) -> Bool) -> Double {
            analysedMs > 0 ? local.filter { include($0.bpm) }.reduce(0) { $0 + $1.ms } / analysedMs : 0
        }

        let completed = records.sorted { $0.ts < $1.ts }.first { $0.classifierState == 2 }
        return EcgRhythmFacts(
            heartRate: rate,
            rateLow: min(rate, EcgBeats.percentile(rates, 0.05) ?? rate),
            rateHigh: max(rate, EcgBeats.percentile(rates, 0.95) ?? rate),
            fractionAboveHigh: shareOfTime { $0 > highRate },
            fractionBelowLow: shareOfTime { $0 < lowRate },
            variationPercent: mean > 0 ? sd / mean * 100 : 0,
            rmssdMs: rmssd,
            setAsideIntervals: setAside,
            strapResultCode: completed?.classifierResult)
    }
}
