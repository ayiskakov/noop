import Foundation
import WhoopProtocol

/// The live R17 waveform a guided MG ECG capture draws while it runs (#891).
///
/// Records arrive in bursts (a whole record per notification), but a sweeping trace has to advance
/// smoothly. This type is the jitter buffer between the two: every record is appended as it lands, and
/// `displayedEnd(at:)` says how many samples a view should show at a given instant, advancing at
/// `playbackRate` behind a short pre-roll so the next burst normally arrives before the trace runs out.
///
/// ## What the pacing is, and is not
///
/// `playbackRate` is a PRESENTATION choice, not a measured sample rate. `docs/PROTOCOL_ECG.md` gives the
/// filtered output only as one value per five processed inputs; paced at 100 per second the trace keeps
/// up with a strap delivering 100 samples per record at one record per second. That figure was never
/// measured, so the buffer corrects in both directions: a slower strap stalls the trace and re-anchors at
/// the next burst, and a faster one is caught up by skipping ahead whenever the undrawn backlog passes
/// `maxBacklog`, so the trace never lags the status line by more than a few records and never falls off
/// the end of the kept samples. Nothing here labels an axis in seconds.
///
/// Pure and clock-free: every method takes the time it should reason about, so the pacing is covered
/// by `swift test` with no timer and no strap.
public struct EcgLiveFeed: Equatable, Sendable {

    /// Samples shown per second of wall time.
    public static let playbackRate = 100.0
    /// Delay between a burst landing and the trace starting to draw it.
    public static let preroll: TimeInterval = 0.4
    /// Samples kept. Thirty seconds at the playback rate — longer than any window a view draws.
    public static let defaultCapacity = 3_000
    /// Undrawn samples allowed to pile up before the trace skips ahead. Two and a half records at the
    /// nominal size: above the backlog an on-time strap leaves just after a burst, well below capacity.
    public static let maxBacklog = 250

    public let capacity: Int
    /// The newest samples, oldest first, at most `capacity`.
    public private(set) var samples: [Int] = []
    /// Samples ever appended. `samples.last`, when present, is sample number `totalSamples - 1`.
    public private(set) var totalSamples = 0
    /// Records accepted.
    public private(set) var records = 0
    /// Records skipped because they repeated the previous record index (a re-sent notification).
    public private(set) var duplicates = 0
    /// Records after which one or more record indices were skipped. The trace does not break for them,
    /// but the count is kept so a missing stretch is visible rather than silently joined.
    public private(set) var gaps = 0
    /// The newest record's packed status: quality, presence, progress, classifier codes, all raw.
    public private(set) var status: Whoop5EcgRawRecord.Status?
    public private(set) var lastRecordIndex: UInt32?
    public private(set) var firstArrival: Date?
    public private(set) var lastArrival: Date?

    /// Playback anchor: sample number `anchorSample` is drawn at `anchorTime`.
    private var anchorSample = 0
    private var anchorTime: Date?

    public init(capacity: Int = EcgLiveFeed.defaultCapacity) {
        self.capacity = max(1, capacity)
    }

    /// Append one decoded R17 record that arrived at `at`. Returns false when it was dropped as a repeat
    /// of the previous record index.
    @discardableResult
    public mutating func append(_ record: Whoop5EcgFilteredRecord.Decoded, at: Date) -> Bool {
        if let last = lastRecordIndex {
            if record.recordIndex == last {
                duplicates += 1
                return false
            }
            // Only forward jumps count as gaps. A lower index is a new session or a wrap, not a hole.
            if record.recordIndex > last, record.recordIndex - last > 1 { gaps += 1 }
        }
        lastRecordIndex = record.recordIndex
        status = record.status
        records += 1
        if firstArrival == nil { firstArrival = at }
        lastArrival = at

        // Re-anchor when the trace has caught up with the data (or never started), so a late burst
        // resumes from where the trace stalled instead of fast-forwarding through it.
        if anchorTime == nil || playhead(at: at) >= Double(totalSamples) {
            anchorSample = totalSamples
            anchorTime = at.addingTimeInterval(Self.preroll)
        }

        samples.append(contentsOf: record.samples)
        totalSamples += record.samples.count
        if samples.count > capacity { samples.removeFirst(samples.count - capacity) }

        // A strap sending faster than the playback rate leaves a growing backlog. Skip ahead so the
        // trace stays one pre-roll behind the newest sample, rather than drawing an ever-older past and,
        // once the lag passes `capacity`, nothing at all.
        if Double(totalSamples) - playhead(at: at) > Double(min(Self.maxBacklog, capacity)) {
            anchorSample = max(0, totalSamples - Int(Self.preroll * Self.playbackRate))
            anchorTime = at
        }
        return true
    }

    /// Unclamped playback position, in samples, at `now`.
    private func playhead(at now: Date) -> Double {
        guard let anchorTime else { return 0 }
        let elapsed = max(0, now.timeIntervalSince(anchorTime))
        return Double(anchorSample) + elapsed * Self.playbackRate
    }

    /// How many samples a view should have drawn by `now`: never more than have arrived, never fewer
    /// than the anchor.
    public func displayedEnd(at now: Date) -> Int {
        min(totalSamples, Int(playhead(at: now)))
    }

    /// The `count` samples ending at `displayedEnd(at:)`, oldest first. Shorter at the start of a capture.
    public func window(endingAt now: Date, count: Int) -> [Int] {
        let end = displayedEnd(at: now)
        let firstKept = totalSamples - samples.count
        let lo = max(firstKept, end - max(0, count))
        guard end > lo else { return [] }
        return Array(samples[(lo - firstKept)..<(end - firstKept)])
    }
}
