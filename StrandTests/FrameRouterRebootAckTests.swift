import XCTest
@testable import Strand
import WhoopProtocol

/// bhelm/noop#4: the reboot-ack diagnostic must read the COMMAND_RESPONSE result byte at the FAMILY's
/// offset — WHOOP 4.0 @8, WHOOP 5/MG @12 (the "+4 shift"). Reading the fixed 4.0 offset on a 5/MG frame
/// hit the inner *type* byte (non-zero) and logged REJECTED on a successful reboot.
///
/// `@MainActor`: `FrameRouter` is a main-actor class, so its static helper is called from the main actor.
@MainActor
final class FrameRouterRebootAckTests: XCTestCase {

    func testCommandResultByteReadsThePuffinResultOffset() {
        // Distinct sentinels at the two candidate result positions, so reading the wrong one is visible.
        var frame = [UInt8](repeating: 0, count: 16)
        frame[8]  = 0x24   // the inner TYPE byte (COMMAND_RESPONSE) — what a smaller fixed offset hit
        frame[12] = 0x01   // the result = SUCCESS(1)

        XCTAssertEqual(FrameRouter.commandResultByte(in: frame, family: .whoop5), 1,
                       "the result lives at byte 12, past the inner type byte")
        XCTAssertEqual(FrameRouter.commandResultByte(in: frame), 1,
                       "the default family reads the same offset")
    }

    func testShortFrameHasNoResultByte() {
        // A 5/MG frame too short to carry a byte-12 result → nil (the log prints "no result byte").
        XCTAssertNil(FrameRouter.commandResultByte(in: [UInt8](repeating: 0, count: 12), family: .whoop5))
    }
}
