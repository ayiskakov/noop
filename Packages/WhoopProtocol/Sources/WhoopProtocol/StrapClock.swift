import Foundation

/// The WHOOP 5/MG strap clock as GET_CLOCK (11) reports it, and whether a connect sets it (W06-050).
///
/// Every connect used to send SET_CLOCK and then GET_CLOCK. The strap applies a SET_CLOCK value when it
/// processes the command, and on a busy link (a state-restoration relaunch) that came about four seconds
/// after the phone stamped the value, so the strap then ran that far behind. The next prompt set stepped it
/// forward again, and when that set came from a relaunch during a Raw Data Collector session the IMU
/// timeline skipped the seconds of the step. Reading first and setting only a clock that is invalid or
/// provably more than `driftThresholdSeconds` off removes both steps for a strap whose clock is fine.
public enum StrapClock {

    /// Seconds at or below this are not a wall clock. The strap applies a stored time only above it
    /// (`docs/PROTOCOL_TRANSPORT.md` §Clock and identity contracts), and a failed read can report zero with
    /// a success result, so a reading here needs a set whatever the result byte says.
    public static let validityFloor: UInt32 = 1_293_840_001

    /// How far the strap clock may sit from the phone's before a connect sets it.
    public static let driftThresholdSeconds: Double = 2

    /// How long a connect waits for the GET_CLOCK reply before setting the clock without one. Replies on a
    /// busy relaunch came about four seconds after the request; a firmware that does not serve GET_CLOCK
    /// never answers, and its strap must still be clocked, because an un-clocked WHOOP 5 banks no sensor data.
    public static let replyTimeoutSeconds: Double = 10

    /// The COMMAND_RESPONSE result that carries a reading. Pending (2) promises a later answer.
    public static let resultSuccess: UInt8 = 1
    public static let resultPending: UInt8 = 2

    /// One GET_CLOCK reply.
    public struct Reading: Equatable, Sendable {
        /// The sequence of the request this answers (format-1 byte 11), which ties the reply to one read.
        public let originSequence: UInt8
        /// The COMMAND_RESPONSE result (byte 12): 0 failure, 1 success, 2 pending, 3 unsupported.
        public let result: UInt8
        /// Whole Unix seconds on the strap clock, or nil when the reply body stops before them.
        public let seconds: UInt32?

        public init(originSequence: UInt8, result: UInt8, seconds: UInt32?) {
            self.originSequence = originSequence; self.result = result; self.seconds = seconds
        }
    }

    /// Decode a format-1 COMMAND_RESPONSE to GET_CLOCK: type 36 at byte 8, command 11 at byte 10, the
    /// request's sequence at 11, the result at 12 and the strap's Unix seconds as a u32 LE at 13. Twenty
    /// replies from firmware 50.39.1.0 have this layout, each followed by seven zero bytes that are not read.
    ///
    /// Structure only: the caller passes a frame that passed `verifyFrame`. The body ends where the declared
    /// length (bytes 2–3) puts the CRC32 trailer. Returns nil for any other frame or a body that stops before
    /// the result.
    public static func decodeReply(_ frame: [UInt8]) -> Reading? {
        guard frame.count >= 4 else { return nil }
        let bodyEnd = 4 + (Int(frame[2]) | Int(frame[3]) << 8)
        guard bodyEnd <= frame.count, bodyEnd > 12, frame[8] == 36, frame[10] == 11 else { return nil }
        var seconds: UInt32?
        if bodyEnd >= 17 {
            seconds = UInt32(frame[13]) | UInt32(frame[14]) << 8 | UInt32(frame[15]) << 16 | UInt32(frame[16]) << 24
        }
        return Reading(originSequence: frame[11], result: frame[12], seconds: seconds)
    }

    /// What one reading says about the strap clock, as the offset strap − phone in seconds.
    public enum Verdict: Equatable, Sendable {
        /// No reading: the result was not success, or the reply carried no seconds.
        case unread(result: UInt8)
        /// A reading at or below `validityFloor`.
        case invalid(seconds: UInt32)
        /// The offset lies within the threshold either way.
        case inSync(seconds: UInt32, low: Double, high: Double)
        /// The offset may pass the threshold, but the round trip was too long to show that it does.
        case unresolved(seconds: UInt32, low: Double, high: Double)
        /// The offset lies wholly beyond the threshold.
        case off(seconds: UInt32, low: Double, high: Double)

        /// Whether a connect should set the clock on this verdict.
        public var needsSet: Bool {
            switch self {
            case .unread, .invalid, .off: return true
            case .inSync, .unresolved: return false
            }
        }
    }

    /// Judge a reading from a GET_CLOCK sent at `sentAt` and answered at `receivedAt`, both phone Unix
    /// seconds. The strap read its clock at some moment in that window, and a whole-second reading `s` means
    /// its clock stood in [s, s + 1) then. So the offset strap − phone lies in (s − receivedAt, s + 1 − sentAt),
    /// and the clock is judged off only when that whole range lies past the threshold. A long round trip
    /// widens the range and so never produces a set by itself.
    public static func judge(_ reading: Reading, sentAt: Double, receivedAt: Double,
                             threshold: Double = driftThresholdSeconds) -> Verdict {
        guard reading.result == resultSuccess, let s = reading.seconds else { return .unread(result: reading.result) }
        guard s > validityFloor else { return .invalid(seconds: s) }
        let low = Double(s) - max(receivedAt, sentAt)
        let high = Double(s) + 1 - sentAt
        if high < -threshold || low > threshold { return .off(seconds: s, low: low, high: high) }
        if low >= -threshold && high <= threshold { return .inSync(seconds: s, low: low, high: high) }
        return .unresolved(seconds: s, low: low, high: high)
    }

    /// One connection's clock check: one read, then a set only when its verdict needs one.
    public struct Check: Equatable, Sendable {

        /// A GET_CLOCK in flight: its request sequence and when it was sent.
        public struct Request: Equatable, Sendable {
            public let sequence: UInt8
            public let sentAt: Double
        }

        /// The read that decides this connection; nil once it has been answered or has expired.
        public private(set) var read: Request?
        /// The GET_CLOCK sent after a set, so its reply is recognised and reported rather than judged.
        public private(set) var readback: Request?
        /// True once the check has decided, by a reply or by the timeout.
        public private(set) var settled = false

        public init() {}

        /// What a reply means for this connection.
        public enum Step: Equatable, Sendable {
            /// Answers no request in flight: a late or foreign reply, reported and otherwise ignored.
            case notOurs
            /// The strap acknowledged the read and will answer later.
            case pending
            /// The read is answered and the clock is left alone.
            case settle(Verdict, roundTrip: Double)
            /// The read is answered and the clock needs a set.
            case set(Verdict, roundTrip: Double)
            /// The reply to the readback after a set; `roundTrip` counts from the set.
            case readback(Reading, roundTrip: Double)
        }

        /// A read went out with request sequence `sequence` at `at`.
        public mutating func beginRead(sequence: UInt8, at: Double) {
            guard !settled else { return }
            read = Request(sequence: sequence, sentAt: at)
        }

        /// A readback went out after a set.
        public mutating func beginReadback(sequence: UInt8, at: Double) {
            readback = Request(sequence: sequence, sentAt: at)
        }

        /// Fold in one decoded reply received at `at`.
        public mutating func receive(_ reading: Reading, at: Double) -> Step {
            if let r = read, !settled, reading.originSequence == r.sequence {
                if reading.result == resultPending { return .pending }
                read = nil
                settled = true
                let verdict = judge(reading, sentAt: r.sentAt, receivedAt: at)
                let roundTrip = at - r.sentAt
                return verdict.needsSet ? .set(verdict, roundTrip: roundTrip) : .settle(verdict, roundTrip: roundTrip)
            }
            if let r = readback, reading.originSequence == r.sequence {
                if reading.result == resultPending { return .pending }
                readback = nil
                return .readback(reading, roundTrip: at - r.sentAt)
            }
            return .notOurs
        }

        /// The read went unanswered for `replyTimeoutSeconds`. True when this settles the check, and the
        /// caller then sets the clock without a reading; false when a reply already settled it.
        public mutating func expire() -> Bool {
            guard !settled else { return false }
            settled = true
            read = nil
            return true
        }
    }

    /// The log line for a verdict, stating the reading and the range it allows rather than a single offset
    /// the reply cannot establish.
    public static func describe(_ verdict: Verdict, roundTrip: Double) -> String {
        let rt = String(format: "%.1f", max(0, roundTrip))
        switch verdict {
        case .unread(let result):
            return "GET_CLOCK answered result \(result) with no reading — setting the clock"
        case .invalid(let s):
            return "strap clock reads \(s), not a wall clock (at or below \(validityFloor)) — setting it"
        case let .inSync(s, low, high):
            return "strap clock reads \(s), \(range(low, high)) from the phone over a \(rt) s round trip — "
                + "within \(Int(driftThresholdSeconds)) s, not set"
        case let .unresolved(s, low, high):
            return "strap clock reads \(s), \(range(low, high)) from the phone over a \(rt) s round trip — "
                + "that does not show it more than \(Int(driftThresholdSeconds)) s off, not set"
        case let .off(s, low, high):
            return "strap clock reads \(s), \(range(low, high)) from the phone over a \(rt) s round trip — "
                + "more than \(Int(driftThresholdSeconds)) s off, setting it"
        }
    }

    private static func range(_ low: Double, _ high: Double) -> String {
        String(format: "%+.1f…%+.1f s", low, high)
    }
}
