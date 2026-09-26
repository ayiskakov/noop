import Foundation

/// The WHOOP 5/MG strap clock as GET_CLOCK (11) reports it (W06-001).
public enum StrapClock {

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
}
