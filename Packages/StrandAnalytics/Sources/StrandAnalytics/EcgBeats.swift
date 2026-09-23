import Foundation
import WhoopProtocol

/// R-peak detection and R-R intervals for a stored WHOOP MG R16 ECG recording (#891).
///
/// EXPERIMENTAL, and scoped to the review screen: nothing here feeds a score, a baseline or a gate.
///
/// ## Why a heart rate is shown at all
///
/// Earlier code refused any ECG-derived rate, citing an agreement with optical HR of r ≈ 0.43. That
/// figure predates the documented R16 decode (signed 18-bit samples at fixed offsets); the earlier
/// readings discarded 42.8 % of samples and joined the survivors, which no beat detector survives. On
/// an MG (fw 50.39.1.0) with the documented decode, this detector (run standalone over the stored
/// records, `swiftc -O`) was compared with the strap's own optical HR notifications at every moment one
/// fell inside a quality-3 stretch: 12 moments across four sessions, optical 82–116 bpm, r = 0.92, mean
/// absolute difference 4.0 bpm, ECG reading 2.0 bpm higher on average (the optical figure is smoothed
/// over tens of seconds). An independent Python analysis of the same records agreed with it per session
/// to within 0.5 bpm. That is a varying input tracked rather than one matched night; the synthetic tests
/// recover several injected rates for the same reason.
///
/// ## What is gated, and why
///
/// Only records the strap itself marked quality 3 are analysed. Over the same captures, quality-0
/// stretches produced beat trains unrelated to the optical HR (mains hum and an open circuit), so the
/// strap's own code is the one gate with evidence behind it. Intervals are measured only between beats
/// inside one contiguous run of such records, never across a gap or a lower-quality record.
///
/// ## Timing
///
/// Samples are placed at `sampleRate` (500 per second). That rate is not in the protocol doc, but it is
/// measured twice over: one 500-sample record per second of strap clock, and mains hum in an open-circuit
/// capture landing at 49.994 Hz under exactly this rate.
public enum EcgBeats {

    /// Samples per second assumed for a full R16 record.
    public static let sampleRate = 500.0
    /// The strap quality code a record needs to be analysed.
    public static let requiredQuality = 3
    /// Shortest contiguous gated stretch worth analysing.
    public static let minSegmentSeconds = 3
    /// R-R intervals outside this range are counted as rejected rather than used (200 and 30 bpm).
    public static let rrRangeMs: ClosedRange<Double> = 300...2_000
    /// Fewest usable intervals before a heart rate is reported.
    public static let minIntervalsForRate = 8

    /// One detected R peak.
    public struct Beat: Equatable, Sendable {
        /// Unix seconds, fractional: the record's timestamp plus the sample's offset within it.
        public let time: Double
        /// Which contiguous gated stretch it came from.
        public let segment: Int
    }

    /// The gap between two successive beats of one stretch.
    public struct Interval: Equatable, Sendable {
        /// Unix seconds of the beat that ends the interval.
        public let endTime: Double
        public let ms: Double
        public let segment: Int

        public init(endTime: Double, ms: Double, segment: Int) {
            self.endTime = endTime
            self.ms = ms
            self.segment = segment
        }
    }

    public struct Result: Equatable, Sendable {
        public let beats: [Beat]
        /// Successive intervals within one stretch that fell inside `rrRangeMs`, in beat order.
        public let intervals: [Interval]
        /// Successive intervals within one stretch that fell outside it.
        public let rejectedIntervals: Int
        /// Seconds of signal that passed the quality gate and were analysed.
        public let analysedSeconds: Int

        public init(beats: [Beat], intervals: [Interval], rejectedIntervals: Int, analysedSeconds: Int) {
            self.beats = beats
            self.intervals = intervals
            self.rejectedIntervals = rejectedIntervals
            self.analysedSeconds = analysedSeconds
        }

        /// The in-range intervals, in milliseconds.
        public var rrMs: [Double] { intervals.map(\.ms) }

        /// Median-based rate, or nil with fewer than `minIntervalsForRate` usable intervals. The median
        /// keeps one missed or doubled beat from moving the figure.
        public var heartRate: Double? {
            guard rrMs.count >= EcgBeats.minIntervalsForRate, let m = EcgBeats.median(rrMs), m > 0 else { return nil }
            return 60_000 / m
        }
        public var medianRRMs: Double? { EcgBeats.median(rrMs) }
    }

    // MARK: - Recording

    /// Detect beats across a recording's stored records, in any order.
    public static func analyse(_ records: [EcgCandidateSample]) -> Result {
        let ordered = records.sorted { ($0.recordIndex ?? $0.ts, $0.ts) < ($1.recordIndex ?? $1.ts, $1.ts) }
        var segments: [[EcgCandidateSample]] = []
        var current: [EcgCandidateSample] = []
        for record in ordered {
            let usable = record.quality >= requiredQuality
                && record.samples.count == Int(sampleRate)
                && record.declaredCount == record.samples.count
            guard usable else {
                if !current.isEmpty { segments.append(current); current = [] }
                continue
            }
            if let last = current.last, !follows(last, record) {
                segments.append(current)
                current = []
            }
            current.append(record)
        }
        if !current.isEmpty { segments.append(current) }
        segments.removeAll { $0.count < minSegmentSeconds }

        var beats: [Beat] = []
        var intervals: [Interval] = []
        var rejected = 0
        for (s, segment) in segments.enumerated() {
            let samples = segment.flatMap { $0.samples.map(Double.init) }
            let peaks = detect(samples, sampleRate: sampleRate)
            let start = Double(segment[0].ts)
            let times = peaks.map { start + Double($0) / sampleRate }
            beats += times.map { Beat(time: $0, segment: s) }
            for i in times.indices.dropFirst() {
                let ms = (times[i] - times[i - 1]) * 1_000
                if rrRangeMs.contains(ms) {
                    intervals.append(Interval(endTime: times[i], ms: ms, segment: s))
                } else {
                    rejected += 1
                }
            }
        }
        return Result(beats: beats, intervals: intervals, rejectedIntervals: rejected,
                      analysedSeconds: segments.reduce(0) { $0 + $1.count })
    }

    /// True when `next` is the record directly after `previous`: the next record index when both carry
    /// one, else the next second.
    private static func follows(_ previous: EcgCandidateSample, _ next: EcgCandidateSample) -> Bool {
        if let a = previous.recordIndex, let b = next.recordIndex { return b == a + 1 }
        return next.ts == previous.ts + 1
    }

    // MARK: - Detection

    /// R-peak sample indices in one contiguous stretch, ascending.
    ///
    /// A reduced Pan–Tompkins: zero-phase 5–20 Hz band-pass (which also takes 50/60 Hz mains down by
    /// more than 60 dB), squared slope, 150 ms moving integration, a threshold at 30 % of the stretch's
    /// 98th percentile, a 250 ms refractory period, and each peak placed on the band-passed signal's
    /// extreme in the stretch's dominant polarity. Polarity is chosen per stretch because the trace's
    /// sign follows the wrist and lead orientation.
    public static func detect(_ samples: [Double], sampleRate fs: Double) -> [Int] {
        let n = samples.count
        guard n >= Int(fs), fs > 0 else { return [] }
        let band = bandPass(samples, sampleRate: fs)

        var energy = [Double](repeating: 0, count: n)
        for i in 1..<(n - 1) {
            let slope = band[i + 1] - band[i - 1]
            energy[i] = slope * slope
        }
        let window = max(1, Int(0.150 * fs))
        var integrated = [Double](repeating: 0, count: n)
        var running = 0.0
        for i in 0..<n {
            running += energy[i]
            if i >= window { running -= energy[i - window] }
            integrated[i] = running / Double(window)
        }

        guard let high = percentile(integrated, 0.98), high > 0 else { return [] }
        let threshold = 0.3 * high
        var candidates: [Int] = []
        for i in 1..<(n - 1) where integrated[i] >= threshold
            && integrated[i] > integrated[i - 1] && integrated[i] >= integrated[i + 1] {
            candidates.append(i)
        }
        let refractory = Int(0.250 * fs)
        let kept = strongestFirst(candidates, height: integrated, spacing: refractory)

        // The integrator lags the complex by up to its window; search back over it, and a little ahead.
        let back = Int(0.200 * fs), ahead = Int(0.050 * fs)
        func extremes(_ p: Int) -> (hi: Int, lo: Int) {
            let a = max(0, p - back), b = min(n - 1, p + ahead)
            var hi = a, lo = a
            for i in a...b {
                if band[i] > band[hi] { hi = i }
                if band[i] < band[lo] { lo = i }
            }
            return (hi, lo)
        }
        let spans = kept.map(extremes)
        let up = spans.reduce(0.0) { $0 + band[$1.hi] }
        let down = spans.reduce(0.0) { $0 - band[$1.lo] }
        let peaks = spans.map { up >= down ? $0.hi : $0.lo }
        let refined = Array(Set(peaks)).sorted()
        return strongestFirst(refined, height: band.map { up >= down ? $0 : -$0 }, spacing: refractory)
    }

    /// Keep the highest candidates first, dropping any within `spacing` of one already kept.
    private static func strongestFirst(_ candidates: [Int], height: [Double], spacing: Int) -> [Int] {
        var kept: [Int] = []
        for c in candidates.sorted(by: { height[$0] > height[$1] })
            where !kept.contains(where: { abs($0 - c) < spacing }) {
            kept.append(c)
        }
        return kept.sorted()
    }

    // MARK: - Filtering

    /// Zero-phase band-pass: two 20 Hz low-pass and one 5 Hz high-pass Butterworth sections, each run
    /// forwards and backwards over a reflected pad so the ends start without a step.
    static func bandPass(_ x: [Double], sampleRate fs: Double) -> [Double] {
        let pad = min(x.count - 1, Int(fs / 2))
        guard pad > 0 else { return x }
        let head = (1...pad).map { 2 * x[0] - x[$0] }.reversed()
        let tail = (1...pad).map { 2 * x[x.count - 1] - x[x.count - 1 - $0] }
        var y = Array(head) + x + tail
        let low = Biquad.lowPass(cutoff: 20, sampleRate: fs)
        let highPass = Biquad.highPass(cutoff: 5, sampleRate: fs)
        for section in [low, low, highPass] {
            y = section.run(y)
            y = section.run(y.reversed()).reversed()
        }
        return Array(y[pad..<(pad + x.count)])
    }

    /// A second-order Butterworth section (RBJ cookbook, Q = 1/√2).
    struct Biquad {
        let b0, b1, b2, a1, a2: Double

        static func lowPass(cutoff: Double, sampleRate: Double) -> Biquad {
            let w = 2 * Double.pi * cutoff / sampleRate, alpha = sin(w) / (2 * 0.5.squareRoot())
            let a0 = 1 + alpha, c = cos(w)
            return Biquad(b0: (1 - c) / 2 / a0, b1: (1 - c) / a0, b2: (1 - c) / 2 / a0,
                          a1: -2 * c / a0, a2: (1 - alpha) / a0)
        }

        static func highPass(cutoff: Double, sampleRate: Double) -> Biquad {
            let w = 2 * Double.pi * cutoff / sampleRate, alpha = sin(w) / (2 * 0.5.squareRoot())
            let a0 = 1 + alpha, c = cos(w)
            return Biquad(b0: (1 + c) / 2 / a0, b1: -(1 + c) / a0, b2: (1 + c) / 2 / a0,
                          a1: -2 * c / a0, a2: (1 - alpha) / a0)
        }

        func run(_ x: [Double]) -> [Double] {
            var y = [Double](repeating: 0, count: x.count)
            var x1 = x.first ?? 0, x2 = x1
            // Start from the steady state of a constant input equal to the first sample, so a large DC
            // offset (the raw samples sit tens of thousands of counts off zero) does not ring.
            let dc = (b0 + b1 + b2) / (1 + a1 + a2)
            var y1 = x1 * dc, y2 = y1
            for i in x.indices {
                let v = b0 * x[i] + b1 * x1 + b2 * x2 - a1 * y1 - a2 * y2
                x2 = x1; x1 = x[i]; y2 = y1; y1 = v
                y[i] = v
            }
            return y
        }
    }

    // MARK: - Statistics

    static func median(_ values: [Double]) -> Double? {
        guard !values.isEmpty else { return nil }
        let s = values.sorted(), m = s.count / 2
        return s.count % 2 == 1 ? s[m] : (s[m - 1] + s[m]) / 2
    }

    static func percentile(_ values: [Double], _ p: Double) -> Double? {
        guard !values.isEmpty else { return nil }
        let s = values.sorted()
        return s[min(s.count - 1, max(0, Int((Double(s.count - 1) * p).rounded())))]
    }
}
