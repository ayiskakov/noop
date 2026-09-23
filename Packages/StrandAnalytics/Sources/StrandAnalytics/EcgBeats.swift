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
/// recover several injected rates for the same reason. The adaptive thresholds in `classify` and the
/// neighbour check came after that comparison. Re-run over five recordings from the same strap (354 s
/// at quality 3), they find the same beats the fixed threshold did, at the same samples, bar four it
/// took that were not complexes, and give the same rate at every moment an optical reading fell in a
/// quality-3 stretch.
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
    /// The strap quality code a record needs to be analysed, exactly: the codes are states, not a scale
    /// (`docs/PROTOCOL_ECG.md` has seen 0–3), so an unknown higher one is not read as better.
    public static let requiredQuality = 3
    /// Shortest contiguous gated stretch worth analysing.
    public static let minSegmentSeconds = 3
    /// R-R intervals outside this range are counted as rejected rather than used (200 and 30 bpm). The
    /// HRV range, so the rhythm facts' cleaning (`HRVAnalyzer.cleanRRGapAware`) rejects the same ones.
    public static let rrRangeMs: ClosedRange<Double> = HRVAnalyzer.rrMinMs...HRVAnalyzer.rrMaxMs
    /// Fewest usable intervals before a heart rate is reported.
    public static let minIntervalsForRate = 8

    /// One detected R peak.
    public struct Beat: Equatable, Sendable {
        /// Timestamp of the stored record the peak lies in.
        public let recordTs: Int
        /// The peak's sample index within that record.
        public let sample: Int
        /// Which contiguous gated stretch it came from.
        public let segment: Int

        /// Unix seconds, fractional: the record's timestamp plus the sample's offset within it. Taken
        /// from the peak's own record, never from the stretch's first one, because a stretch is
        /// contiguous by record index and the strap's clock can be corrected partway through it.
        public var time: Double { Double(recordTs) + Double(sample) / EcgBeats.sampleRate }
    }

    /// The gap between two successive beats of one stretch.
    public struct Interval: Equatable, Sendable {
        public let ms: Double
        public let segment: Int

        public init(ms: Double, segment: Int) {
            self.ms = ms
            self.segment = segment
        }

        /// Inside `rrRangeMs`, and so used for the rate.
        public var isUsable: Bool { EcgBeats.rrRangeMs.contains(ms) }
    }

    public struct Result: Equatable, Sendable {
        public let beats: [Beat]
        /// EVERY successive interval within one stretch, in beat order, including those outside
        /// `rrRangeMs`. Kept whole so a successive-difference measure can tell which usable intervals
        /// were adjacent: dropping a rejected one from this list would splice its neighbours together.
        public let intervals: [Interval]
        /// Seconds of signal that passed the quality gate and were analysed.
        public let analysedSeconds: Int

        public init(beats: [Beat], intervals: [Interval], analysedSeconds: Int) {
            self.beats = beats
            self.intervals = intervals
            self.analysedSeconds = analysedSeconds
        }

        /// Successive intervals that fell outside `rrRangeMs`.
        public var rejectedIntervals: Int { intervals.count - rrMs.count }

        /// The in-range intervals, in milliseconds.
        public var rrMs: [Double] { intervals.filter(\.isUsable).map(\.ms) }

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
        // The order and continuity rule `EcgStrip.group` uses, so a stretch never spans two recordings.
        let ordered = records.sorted { EcgStrip.recordOrder(($0.recordIndex, $0.ts), ($1.recordIndex, $1.ts)) }
        let perRecord = Int(sampleRate)
        var segments: [[EcgCandidateSample]] = []
        var current: [EcgCandidateSample] = []
        for record in ordered {
            let usable = record.quality == requiredQuality
                && record.samples.count == perRecord
                && record.declaredCount == record.samples.count
            guard usable else {
                if !current.isEmpty { segments.append(current); current = [] }
                continue
            }
            if let last = current.last,
               !EcgStrip.continuesRun(previous: (last.recordIndex, last.ts), next: (record.recordIndex, record.ts)) {
                segments.append(current)
                current = []
            }
            current.append(record)
        }
        if !current.isEmpty { segments.append(current) }
        segments.removeAll { $0.count < minSegmentSeconds }

        var beats: [Beat] = []
        var intervals: [Interval] = []
        for (s, segment) in segments.enumerated() {
            let samples = segment.flatMap { $0.samples.map(Double.init) }
            let peaks = detect(samples, sampleRate: sampleRate)
            // Every record here holds exactly `perRecord` samples, so a peak's record is its index over
            // that. Intervals are counted in samples: the stretch is continuous on the strap's sample
            // clock even where its wall clock was corrected.
            beats += peaks.map { Beat(recordTs: segment[$0 / perRecord].ts, sample: $0 % perRecord, segment: s) }
            for (a, b) in zip(peaks, peaks.dropFirst()) {
                intervals.append(Interval(ms: Double(b - a) / sampleRate * 1_000, segment: s))
            }
        }
        return Result(beats: beats, intervals: intervals, analysedSeconds: segments.reduce(0) { $0 + $1.count })
    }

    // MARK: - Detection

    /// R-peak sample indices in one contiguous stretch, ascending.
    ///
    /// A reduced Pan–Tompkins: zero-phase 5–20 Hz band-pass (which also takes 50/60 Hz mains down by
    /// more than 60 dB), squared slope, 150 ms moving integration, Pan–Tompkins' running signal and
    /// noise thresholds with search-back (`classify`), a 250 ms refractory period, each peak placed on
    /// the band-passed signal's extreme in the stretch's dominant polarity, and a check of that extreme
    /// against the neighbouring beats' (`inLineWithNeighbours`). Polarity is chosen per stretch because
    /// the trace's sign follows the wrist and lead orientation.
    public static func detect(_ samples: [Double], sampleRate fs: Double) -> [Int] {
        let n = samples.count
        guard fs > 0, n >= max(3, Int(fs)) else { return [] }
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
        let refractory = Int(0.250 * fs)
        var maxima: [Int] = []
        for i in 1..<(n - 1) where integrated[i] > integrated[i - 1] && integrated[i] >= integrated[i + 1] {
            maxima.append(i)
        }
        let kept = classify(strongestFirst(maxima, height: integrated, spacing: refractory),
                            height: integrated, sampleRate: fs)

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
        let height = band.map { up >= down ? $0 : -$0 }
        return inLineWithNeighbours(strongestFirst(refined, height: height, spacing: refractory), height: height)
    }

    /// Peaks whose band-passed height, in the stretch's polarity, is in line with the beats around them:
    /// of the two medians, over the four beats before and the four after, at least half the smaller and
    /// at most four times the larger.
    ///
    /// The running threshold judges energy, which a spike of the wrong polarity has plenty of; this
    /// judges the deflection the beat is placed on. Half the amplitude is the quarter energy the
    /// threshold works at. Each side is taken separately so a step in amplitude, where the beats on one
    /// side are all smaller, does not read as an outlier, and at a stretch end the one side there is
    /// decides. Over one MG's captures (five recordings, 354 s of quality 3) the running threshold
    /// alone took two opposite-polarity spikes for beats; this check removes them, and three detections
    /// the fixed threshold had also made (a dip at each end of one stretch and the onset of a large
    /// step), and nothing that was a complex.
    static func inLineWithNeighbours(_ peaks: [Int], height: [Double]) -> [Int] {
        guard peaks.count >= 3 else { return peaks }
        return peaks.indices.filter { i in
            let before = median(peaks[max(0, i - 4)..<i].map { height[$0] })
            let after = median(peaks[(i + 1)..<min(peaks.count, i + 5)].map { height[$0] })
            let sides = [before, after].compactMap { $0 }.filter { $0 > 0 }
            guard let low = sides.min(), let high = sides.max() else { return true }
            return height[peaks[i]] >= 0.5 * low && height[peaks[i]] <= 4 * high
        }.map { peaks[$0] }
    }

    /// Pan–Tompkins' adaptive thresholds over candidate peaks of the integrated signal (ascending, at
    /// most one per refractory period): the QRS subset.
    ///
    /// One threshold per stretch loses every beat wherever the complexes shrink, as they do when the
    /// finger's pressure on the clasp eases: a swing between 0.4 and 1.0 of full amplitude lost 22 of 72
    /// beats to a fixed 30 % of the stretch's 98th percentile, silently, since the median rate holds. Here
    /// the threshold sits a quarter of the way from a running noise level to a running signal level,
    /// each updated by the candidates as they are classified (weight 1/8), so it follows the amplitude.
    /// When no beat has been found for 1.66 times the mean of the last eight R-R intervals, the gap is
    /// searched again at half the threshold and its strongest candidate taken, which is how a lone
    /// small complex after a large one is recovered.
    ///
    /// One change from the original: a candidate's height enters the signal level capped at twice the
    /// level. Uncapped, one second of motion artefact classified as three or four beats lifts the level
    /// so far that no later complex clears even the search-back threshold, and nothing ever brings it
    /// down, so the rest of the stretch goes silent. Capped, the level rises at most an eighth per beat:
    /// a burst moves it little, and a genuine rise in amplitude is followed over a few more beats.
    ///
    /// The levels are learned from the start of the stretch, as in the original, but robustly: the
    /// signal level is the median of the highest point in each of the first three two-second blocks (at
    /// 30 bpm every block still holds a beat), and the noise level is the stretch's median, which lies
    /// between complexes. Learned from the whole stretch instead, a recording whose complexes grow
    /// threefold partway starts above every complex before the growth.
    ///
    /// The start's level is capped, though, at the same median taken over every block of the stretch.
    /// The filters carry an artefact across a block boundary, so one second of it near the start can
    /// lift two of the three blocks, and a level learned from those holds every later complex under the
    /// threshold with no rhythm yet for a search-back: the stretch went silent. Over 510 placements of
    /// a burst in the first eight seconds (0.3 to 2 s long, 40 to 150 bpm), the uncapped level lost most
    /// of the stretch 60 times; capped, never, and no beat was added. The cap leaves the growth case
    /// alone, where the start is the smaller of the two.
    ///
    /// What it cannot follow:
    /// - an abrupt fall below about 0.4 of the amplitude (0.4 itself is followed to 150 bpm, 0.35 is
    ///   not from 75 bpm, and at 170 bpm and above 0.4 already loses some): those complexes sit below
    ///   even the search-back threshold;
    /// - complexes alternating beat by beat between full and about half amplitude or less. Every smaller
    ///   one sits under the threshold, and the search-back takes the doubled interval for the rhythm, so
    ///   none is recovered and the rate reads half. Down to 0.55, every beat is found at 60 to 150 bpm
    ///   (at 170, down to 0.65); the most eight successive beats alternated over one MG's captures was
    ///   to 0.65.
    ///
    /// Either way, the missing complexes go unmarked on the strip.
    static func classify(_ candidates: [Int], height h: [Double], sampleRate fs: Double) -> [Int] {
        guard !candidates.isEmpty else { return [] }
        let block = max(1, Int(2 * fs))
        let blockPeaks = stride(from: 0, to: h.count, by: block).map { h[$0..<min(h.count, $0 + block)].max() ?? 0 }
        var signal = min(median(Array(blockPeaks.prefix(3))) ?? 0, median(blockPeaks) ?? 0)
        var noise = median(h) ?? 0
        var threshold: Double { noise + 0.25 * (signal - noise) }

        var beats: [Int] = []
        var rr: [Int] = []
        // Candidates classified as noise since the last beat: where a search-back looks.
        var passed: [Int] = []

        func searchBack(before end: Int) {
            while let last = beats.last, !rr.isEmpty {
                let recent = rr.suffix(8)
                let mean = Double(recent.reduce(0, +)) / Double(recent.count)
                guard Double(end - last) > 1.66 * mean,
                      let found = passed.filter({ h[$0] >= 0.5 * threshold }).max(by: { h[$0] < h[$1] })
                else { return }
                signal = 0.25 * min(h[found], 2 * signal) + 0.75 * signal
                rr.append(found - last)
                beats.append(found)
                passed.removeAll { $0 <= found }
            }
        }

        for c in candidates {
            searchBack(before: c)
            if h[c] >= threshold {
                signal = 0.125 * min(h[c], 2 * signal) + 0.875 * signal
                if let last = beats.last { rr.append(c - last) }
                beats.append(c)
                passed.removeAll()
            } else {
                noise = 0.125 * h[c] + 0.875 * noise
                passed.append(c)
            }
        }
        searchBack(before: h.count)
        return beats
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
        values.isEmpty ? nil : HRVAnalyzer.median(values)
    }

    static func percentile(_ values: [Double], _ p: Double) -> Double? {
        guard !values.isEmpty else { return nil }
        let s = values.sorted()
        return s[min(s.count - 1, max(0, Int((Double(s.count - 1) * p).rounded())))]
    }
}
