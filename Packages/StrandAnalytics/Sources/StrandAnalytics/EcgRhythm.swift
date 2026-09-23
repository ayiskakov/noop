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

    /// Intervals per rolling window for the rate series. Five, so one missed or doubled beat moves a
    /// window's median by at most one position rather than setting its value.
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
    /// 5th and 95th percentiles of the rolling rate: the range the rate moved through, without the
    /// single-window extremes an artefact produces.
    public let rateLow: Double
    public let rateHigh: Double
    /// Share of rolling-rate windows above `highRate` / below `lowRate`, 0…1.
    public let fractionAboveHigh: Double
    public let fractionBelowLow: Double
    /// Coefficient of variation of the kept intervals, in percent.
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

        var rolling: [Double] = []
        var nn: [Double] = []
        var contiguous: [Bool] = []
        var setAside = 0
        for raw in bySegment {
            let ms = raw.filter(EcgBeats.rrRangeMs.contains)
            if ms.isEmpty { continue }
            if ms.count < rollingWindow {
                rolling.append(60_000 / (EcgBeats.median(ms) ?? ms[0]))
            } else {
                for start in 0...(ms.count - rollingWindow) {
                    rolling.append(60_000 / (EcgBeats.median(Array(ms[start..<(start + rollingWindow)])) ?? 1))
                }
            }
            let clean = HRVAnalyzer.cleanRRGapAware(raw, radius: neighbourReach)
            setAside += ms.count - clean.nn.count
            // Each stretch's first kept interval is marked non-contiguous, so no difference is taken
            // across a stretch boundary when the stretches are appended.
            nn += clean.nn
            contiguous += clean.contiguous
        }

        let mean = nn.isEmpty ? 0 : nn.reduce(0, +) / Double(nn.count)
        let sd = HRVAnalyzer.sdnnRaw(nn) ?? 0
        let rmssd = HRVAnalyzer.rmssdGapAware(nn, contiguous)

        let completed = records.sorted { $0.ts < $1.ts }.first { $0.classifierState == 2 }
        return EcgRhythmFacts(
            heartRate: rate,
            rateLow: EcgBeats.percentile(rolling, 0.05) ?? rate,
            rateHigh: EcgBeats.percentile(rolling, 0.95) ?? rate,
            fractionAboveHigh: Double(rolling.filter { $0 > highRate }.count) / Double(max(1, rolling.count)),
            fractionBelowLow: Double(rolling.filter { $0 < lowRate }.count) / Double(max(1, rolling.count)),
            variationPercent: mean > 0 ? sd / mean * 100 : 0,
            rmssdMs: rmssd,
            setAsideIntervals: setAside,
            strapResultCode: completed?.classifierResult)
    }
}
