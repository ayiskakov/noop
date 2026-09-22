import Foundation

/// The pure arithmetic behind the gated R16 ECG review strip (#891): grouping stored records into
/// recordings, rendering a waveform to a fixed number of pixel columns, and the one display filter the
/// strip applies.
///
/// Platform-pure and database-free, so `swift test` covers all of it with no app, no strap and no
/// CoreBluetooth — which matters here more than usual, because a waveform is the one thing a reviewer
/// cannot check by reading the code. The SwiftUI layer above this owns only layout and colour.
///
/// ## What this does NOT compute
///
/// No heart rate, no interval, no rhythm classification, no volts. `ECG_FEATURE_NOTES.md` §5 records
/// why: beat-to-beat accuracy against the strap's own optical HR was never established (r ≈ 0.43 at
/// best, and worse with a better detector), for a reason that is structural rather than fixable — wrist
/// single-lead ECG needs stillness, stillness means the heart rate barely moves, and anything that moves
/// it properly destroys the trace. A number on this screen would be the #194 PPG→HR withdrawal again.
/// The strip shows the SHAPE of what the strap recorded and nothing derived from it.
public enum EcgStrip {

    // MARK: - Records in, recordings out

    /// One stored R16 record, reduced to the fields grouping needs. A plain value rather than the store's
    /// row type, so this module stays free of WhoopStore.
    public struct RecordRef: Equatable, Sendable {
        public let ts: Int
        /// The monotonic lifetime record index, or nil where the record's header could not be read.
        public let recordIndex: Int?
        public let storedCount: Int
        public let declaredCount: Int
        public let quality: Int
        public let progress: Int
        /// The slower contact/lead-state entries for this record; empty where it carried no such stream.
        public let contactFlags: [Bool]

        public init(ts: Int, recordIndex: Int?, storedCount: Int, declaredCount: Int,
                    quality: Int, progress: Int, contactFlags: [Bool]) {
            self.ts = ts
            self.recordIndex = recordIndex
            self.storedCount = storedCount
            self.declaredCount = declaredCount
            self.quality = quality
            self.progress = progress
            self.contactFlags = contactFlags
        }
    }

    /// A run of consecutive records: what a person would call "a recording".
    public struct Recording: Equatable, Sendable, Identifiable {
        public let deviceId: String
        /// Wall-clock seconds of the first and last record. `endTs` is the last record's own second, so
        /// the recording covers `[startTs, endTs + 1)` — a one-record recording is one second long.
        public let startTs: Int
        public let endTs: Int
        public let recordCount: Int
        /// Samples actually stored, and samples the records declared. These agree on every cleanly
        /// decoded recording; surfacing both is what lets the screen say so rather than imply it.
        public let storedSamples: Int
        public let declaredSamples: Int
        /// Contact entries that read closed, out of the total the recording carried. Reported as the
        /// count it is — the strap's own lead-state flag — never as a percentage of "signal quality".
        public let contactClosed: Int
        public let contactTotal: Int
        /// The highest `progress` byte any record in the run carried. 100 means a session ran to
        /// completion; 255 is the strap's "no session" value and is reported as absent rather than as a
        /// progress of 255.
        public let peakProgress: Int?

        public var id: String { "\(deviceId)-\(startTs)" }
        /// Seconds covered, counting each record as the one second it represents.
        public var durationSeconds: Int { endTs - startTs + 1 }
        /// True when every declared sample reached storage. False is not cosmetic: it means the strip is
        /// drawing fewer samples than the strap sent, and the screen must say so.
        public var isComplete: Bool { storedSamples == declaredSamples }

        public init(deviceId: String, startTs: Int, endTs: Int, recordCount: Int,
                    storedSamples: Int, declaredSamples: Int, contactClosed: Int, contactTotal: Int,
                    peakProgress: Int?) {
            self.deviceId = deviceId
            self.startTs = startTs
            self.endTs = endTs
            self.recordCount = recordCount
            self.storedSamples = storedSamples
            self.declaredSamples = declaredSamples
            self.contactClosed = contactClosed
            self.contactTotal = contactTotal
            self.peakProgress = peakProgress
        }
    }

    /// The strap's `progress` value for "no session is running". Reported as absent, never as 255.
    public static let progressNoSession = 255

    /// Group one device's records into recordings.
    ///
    /// Contiguity is decided on `recordIndex` — the monotonic lifetime counter — and only falls back to
    /// `ts` for records that carry no index. That ordering is deliberate: the index advances by exactly
    /// one per record whatever the strap's real-time clock is doing, so a clock correction mid-session
    /// leaves the index run intact while it would tear a `ts`-gap heuristic in half and present one
    /// recording as two. The reverse error is not symmetric — two genuinely separate sessions cannot
    /// share consecutive indices, because the counter advances for every record the strap writes.
    ///
    /// `records` need not be sorted. Records from more than one device must not be mixed: pass one
    /// device's records at a time, since two straps' index spaces are unrelated.
    public static func group(deviceId: String, records: [RecordRef]) -> [Recording] {
        guard !records.isEmpty else { return [] }
        let sorted = records.sorted { a, b in
            switch (a.recordIndex, b.recordIndex) {
            case let (x?, y?) where x != y: return x < y
            default: return a.ts < b.ts
            }
        }
        var out: [Recording] = []
        var run: [RecordRef] = [sorted[0]]
        for r in sorted.dropFirst() {
            if continuesRun(previous: run[run.count - 1], next: r) {
                run.append(r)
            } else {
                out.append(summarise(deviceId: deviceId, run: run))
                run = [r]
            }
        }
        out.append(summarise(deviceId: deviceId, run: run))
        // Newest first: the recording someone wants is almost always the one they just made.
        return out.sorted { $0.startTs > $1.startTs }
    }

    /// Whether `next` continues the run `previous` ends.
    ///
    /// Exposed so the rule can be tested directly rather than only through a grouping result.
    public static func continuesRun(previous: RecordRef, next: RecordRef) -> Bool {
        if let a = previous.recordIndex, let b = next.recordIndex { return b == a + 1 }
        // No index on one side or the other: fall back to adjacent seconds. One second of slack, because
        // the records themselves are one per second and an exactly-equal ts would be a duplicate row the
        // primary key does not allow.
        return next.ts == previous.ts + 1
    }

    private static func summarise(deviceId: String, run: [RecordRef]) -> Recording {
        let progresses = run.map(\.progress).filter { $0 != progressNoSession }
        return Recording(
            deviceId: deviceId,
            startTs: run.map(\.ts).min() ?? 0,
            endTs: run.map(\.ts).max() ?? 0,
            recordCount: run.count,
            storedSamples: run.reduce(0) { $0 + $1.storedCount },
            declaredSamples: run.reduce(0) { $0 + $1.declaredCount },
            contactClosed: run.reduce(0) { $0 + $1.contactFlags.filter { $0 }.count },
            contactTotal: run.reduce(0) { $0 + $1.contactFlags.count },
            peakProgress: progresses.max())
    }

    // MARK: - The display filter

    /// Default high-pass corner for the display filter, in hertz.
    ///
    /// 0.5 Hz is the low corner clinical ECG monitors use for exactly this job, and the captures need it:
    /// a ten-second window of real data spans about 28,000 counts of baseline wander against complexes a
    /// few thousand counts tall, so an unfiltered strip is a drifting ramp with the signal riding
    /// invisibly on it.
    public static let defaultHighPassHz = 0.5

    /// Remove baseline wander with a one-pole high-pass, returning a new series.
    ///
    /// DISPLAY ONLY, and the screen says so. Nothing filtered here is written back, exported, or fed to
    /// anything — `samples` on disk stay the strap's own values, because this table exists so a future
    /// analysis can work from the ORIGINAL samples and a filtered archive would defeat that entirely.
    ///
    /// `sampleRate` is supplied by the caller rather than assumed. The record capacity is 500 slots and
    /// the cadence is one record per second, but `docs/PROTOCOL_ECG.md` is explicit that neither
    /// establishes a sample frequency — so this function takes the rate as a parameter and the caller
    /// takes responsibility for it.
    ///
    /// Returns the input unchanged when it is too short to filter, rather than a series of zeros.
    public static func highPass(_ samples: [Double], sampleRate: Double,
                                cutoffHz: Double = defaultHighPassHz) -> [Double] {
        guard samples.count > 1, sampleRate > 0, cutoffHz > 0 else { return samples }
        let rc = 1.0 / (2.0 * .pi * cutoffHz)
        let dt = 1.0 / sampleRate
        let alpha = rc / (rc + dt)
        var out = [Double](repeating: 0, count: samples.count)
        var previous = 0.0
        for i in 1..<samples.count {
            previous = alpha * (previous + samples[i] - samples[i - 1])
            out[i] = previous
        }
        // The filter's first output has no predecessor to difference against, so it is zero by
        // construction. Copying the second value into it keeps a single spurious step off the left edge
        // of every strip.
        out[0] = out.count > 1 ? out[1] : 0
        return out
    }

    // MARK: - Rendering a waveform to pixel columns

    /// One pixel column's vertical extent.
    public struct Column: Equatable, Sendable {
        public let min: Double
        public let max: Double
        public init(min: Double, max: Double) {
            self.min = min
            self.max = max
        }
    }

    /// Reduce a waveform to `columns` min/max pairs.
    ///
    /// Min/max per column rather than sampling or averaging, and that choice is the whole reason this
    /// function exists. A 64-second recording is about 32,000 samples drawn into perhaps 700 pixels, so
    /// roughly 45 samples share every column. Taking one of them (decimation) drops R-peaks whenever the
    /// peak lands on a sample the stride skips — the deflection the strip exists to show, missing at
    /// random. Averaging is worse: it flattens every peak in proportion to how narrow it is, so a sharp
    /// complex is attenuated more than a slow drift, and the strip systematically understates exactly
    /// what it should emphasise. Carrying both extremes of each column preserves the envelope exactly:
    /// no deflection present in the data can be absent from the picture.
    ///
    /// Returns `[]` for an empty input or a non-positive column count.
    public static func envelope(_ samples: [Double], columns: Int) -> [Column] {
        guard columns > 0, !samples.isEmpty else { return [] }
        // More columns than samples would make empty ones. Fall back to one column per sample; the view
        // stretches them, which is honest — it shows the data is sparser than the space given to it.
        let n = Swift.min(columns, samples.count)
        var out: [Column] = []
        out.reserveCapacity(n)
        for c in 0..<n {
            let lo = c * samples.count / n
            let hi = Swift.max(lo + 1, (c + 1) * samples.count / n)
            var mn = samples[lo], mx = samples[lo]
            for i in lo..<Swift.min(hi, samples.count) {
                if samples[i] < mn { mn = samples[i] }
                if samples[i] > mx { mx = samples[i] }
            }
            out.append(Column(min: mn, max: mx))
        }
        return out
    }

    /// The vertical range to draw `columns` in: the data's own extent, padded, and never zero-height.
    ///
    /// Self-scaling to the window rather than to the amplifier rail, because the rail is ±126,976 and a
    /// resting complex is a few thousand counts — drawn against the rail the whole recording is a flat
    /// line. The cost is that two windows are not comparable by eye, which is the right trade for a
    /// signal with no calibrated scale to compare against in the first place.
    public static func verticalRange(_ columns: [Column], padding: Double = 0.08)
        -> (min: Double, max: Double) {
        guard let lo = columns.map(\.min).min(), let hi = columns.map(\.max).max() else { return (-1, 1) }
        let span = hi - lo
        // A perfectly flat window (an all-zero record, or a rail-pinned one) has no span to pad, so it
        // gets a unit range and draws as a centred flat line rather than dividing by zero.
        guard span > 0 else { return (lo - 1, hi + 1) }
        let pad = span * padding
        return (lo - pad, hi + pad)
    }

    // MARK: - Laying records onto a timeline

    /// Concatenate a recording's records into one series, inserting nothing for a missing second.
    ///
    /// Gaps are REPORTED, never filled. A recording is a run of consecutive record indices, so a missing
    /// second inside one can only come from a record that decoded no samples — and interpolating across
    /// it would draw a smooth line through a stretch where the strap recorded nothing, which is a
    /// fabricated waveform. The returned `gapAfter` indices mark the sample positions the caller should
    /// break the trace at.
    public static func concatenate(_ records: [(ts: Int, samples: [Double])])
        -> (samples: [Double], gapAfter: Set<Int>) {
        var samples: [Double] = []
        var gaps: Set<Int> = []
        var previousTs: Int?
        for record in records.sorted(by: { $0.ts < $1.ts }) {
            if let p = previousTs, record.ts != p + 1, !samples.isEmpty {
                gaps.insert(samples.count - 1)
            }
            samples.append(contentsOf: record.samples)
            previousTs = record.ts
        }
        return (samples, gaps)
    }

    /// Apply the display filter to each unbroken stretch separately.
    ///
    /// Filtering across a gap is what a naive implementation gets wrong: the step between the last
    /// sample before a gap and the first after it is a discontinuity the high-pass responds to with a
    /// large transient, which then decays over the following samples — manufacturing a deflection that
    /// looks exactly like a complex at the one place where the strap recorded nothing.
    public static func filterSegments(_ samples: [Double], gapAfter: Set<Int>, sampleRate: Double,
                                      cutoffHz: Double = defaultHighPassHz) -> [Double] {
        guard !samples.isEmpty else { return [] }
        var out: [Double] = []
        out.reserveCapacity(samples.count)
        var start = 0
        for i in 0..<samples.count where gapAfter.contains(i) || i == samples.count - 1 {
            let end = i + 1
            out.append(contentsOf: highPass(Array(samples[start..<end]), sampleRate: sampleRate,
                                            cutoffHz: cutoffHz))
            start = end
        }
        return out
    }
}
