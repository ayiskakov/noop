import Foundation

/// Who in this app owns a realtime raw stream (packet type 43 or 51 that is not an ECG record) arriving now.
///
/// One resolver, so the strap-log note about such a stream cannot disagree with itself about who started it
/// (W06-061). Nothing here sends anything: an automatic stop is outside the BLE contract (W06-018).
///
/// The order is the rule. A capture this process armed comes first, since it logs its own lines. An ECG
/// session comes next: on 2026-09-23 every long type-43 stream ran from an ECG turn-on to its stop, and the
/// note was the only trace of one. Then the store: before it is built, the strap the stream banks under is
/// unknown, and a state-restoration relaunch delivers its first frames in exactly that window (W06-054).
/// Last, a Raw Data Collector session still open on disk for that strap, which a relaunch mid-session has
/// not re-armed yet but whose stream still banks into it (W06-052).
///
/// Pure, so the whole decision table is pinned without a strap, a store or the host app's defaults.
enum RealtimeRawOwner: Equatable {
    /// A capture this process armed, the research toggle's continuous capture, or the tail of a capture
    /// stopped less than `tailSeconds` ago.
    case capture
    /// An ECG session from this app may still be generating: its turn-on requests went out and no stop has,
    /// or a probe's listen window is open. Live type-43 frames arrive while generation runs
    /// (`docs/PROTOCOL_ECG.md` §Hardware observations).
    case ecgSession
    /// The store is not built yet, so whether a session is open for the strap cannot be told.
    case unknownUntilStoreReady
    /// A Raw Data Collector session still open on disk for the strap the stream banks under.
    case openSession
    /// Nothing in this app armed it: a crashed capture or another client left it running.
    case none

    /// How long after a capture's stop its stream may still deliver the last buffers.
    static let tailSeconds: TimeInterval = 3

    /// `sessionOpen` is nil while the store is not built.
    static func resolve(captureArmed: Bool, continuousCapture: Bool, sinceCaptureStop: TimeInterval,
                        ecgMayBeGenerating: Bool, sessionOpen: Bool?) -> RealtimeRawOwner {
        if captureArmed || continuousCapture || sinceCaptureStop < tailSeconds { return .capture }
        if ecgMayBeGenerating { return .ecgSession }
        guard let sessionOpen else { return .unknownUntilStoreReady }
        return sessionOpen ? .openSession : .none
    }
}

/// The strap-log line a realtime raw stream earns: one per stream, naming its owner.
///
/// A stream is one owner's run of frames with no pause of `streamGap` or longer, so a stream that stops and
/// a later one both get a line, and so does a stream whose owner changes (an ECG stop that leaves it
/// running). A frame a capture or an open session owns ends the run; a frame whose owner cannot be told yet
/// neither starts nor ends one. The link's end resets it (`reset`).
struct RealtimeRawNote {
    static let streamGap: TimeInterval = 60
    private var last: (owner: RealtimeRawOwner, at: Date)?

    /// The line for a frame of `packetType` that `owner` owns, or nil when the stream is owned by a capture or
    /// a session, cannot be attributed yet, or was already noted.
    mutating func line(packetType: UInt8, owner: RealtimeRawOwner, now: Date) -> String? {
        let what: String
        switch owner {
        case .capture, .openSession:
            last = nil
            return nil
        case .unknownUntilStoreReady:
            return nil
        case .ecgSession:
            what = "while an ECG session from this app may still be generating"
        case .none:
            what = "with no capture or ECG session armed in this app"
        }
        let noted = last.map { $0.owner == owner && now.timeIntervalSince($0.at) < Self.streamGap } ?? false
        last = (owner, now)
        if noted { return nil }
        return "Raw IMU: realtime packet type \(packetType) is arriving \(what); "
            + "nothing is sent to stop it (noted once per stream)"
    }

    mutating func reset() { last = nil }
}
