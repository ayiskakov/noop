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
    /// An interval further than this fraction from its neighbours' median is set aside as a likely
    /// missed or extra detection before variability is measured. 20 % is the usual artefact rule for
    /// R-R series.
    public static let artefactFraction = 0.20
    /// Intervals either side that form an interval's reference median.
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
    /// of adjacent intervals in one stretch count.
    public let rmssdMs: Double?
    /// Intervals set aside by the artefact rule.
    public let setAsideIntervals: Int
    /// The strap's own classifier result code, from the first record where its classifier state
    /// reached 2 (observed when progress completes); nil when it never got there.
    public let strapResultCode: Int?

    /// Facts for a recording, or nil when `EcgBeats` found too few intervals for a rate.
    public static func from(_ beats: EcgBeats.Result, records: [EcgCandidateSample]) -> EcgRhythmFacts? {
        guard let rate = beats.heartRate else { return nil }
        let bySegment = Dictionary(grouping: beats.intervals, by: \.segment)
            .sorted { $0.key < $1.key }.map(\.value)

        var rolling: [Double] = []
        var kept: [[Double]] = []
        var setAside = 0
        for segment in bySegment {
            let ms = segment.map(\.ms)
            if ms.count < rollingWindow {
                rolling.append(60_000 / (EcgBeats.median(ms) ?? ms[0]))
            } else {
                for start in 0...(ms.count - rollingWindow) {
                    rolling.append(60_000 / (EcgBeats.median(Array(ms[start..<(start + rollingWindow)])) ?? 1))
                }
            }
            // Neighbour median: up to `neighbourReach` intervals either side, excluding the interval
            // itself. Wide enough that a split beat (two short intervals) cannot drag the reference
            // down and take its correct neighbours out with it.
            var run: [Double] = []
            for i in ms.indices {
                let lo = max(0, i - neighbourReach), hi = min(ms.count, i + neighbourReach + 1)
                let neighbours = (lo..<hi).filter { $0 != i }.map { ms[$0] }
                let reference = EcgBeats.median(neighbours) ?? ms[i]
                if abs(ms[i] - reference) > artefactFraction * reference {
                    setAside += 1
                    if !run.isEmpty { kept.append(run); run = [] }
                } else {
                    run.append(ms[i])
                }
            }
            if !run.isEmpty { kept.append(run) }
        }

        let all = kept.flatMap { $0 }
        let mean = all.isEmpty ? 0 : all.reduce(0, +) / Double(all.count)
        let sd = all.count > 1
            ? (all.reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / Double(all.count - 1)).squareRoot()
            : 0
        var squares: [Double] = []
        for run in kept where run.count > 1 {
            for i in run.indices.dropFirst() { squares.append((run[i] - run[i - 1]) * (run[i] - run[i - 1])) }
        }
        let rmssd = squares.isEmpty ? nil : (squares.reduce(0, +) / Double(squares.count)).squareRoot()

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
