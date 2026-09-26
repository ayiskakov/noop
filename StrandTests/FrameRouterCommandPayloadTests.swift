import XCTest
@testable import Strand
import WhoopProtocol

/// W06-065: `commandResponsePayload` must end the payload where the declared length (bytes 2–3) puts the
/// CRC32 trailer. It read bytes 1–2, which on every real 5/MG reply pointed past the frame and returned
/// nil, so the GET_HELLO identity probe (#1303), its only caller, never printed. The two frames are real
/// replies from a WHOOP MG on firmware 50.39.1.0.
@MainActor
final class FrameRouterCommandPayloadTests: XCTestCase {

    private func bytes(_ s: String) -> [UInt8] {
        stride(from: 0, to: s.count, by: 2).map { i in
            let a = s.index(s.startIndex, offsetBy: i)
            return UInt8(s[a...s.index(a, offsetBy: 1)], radix: 16)!
        }
    }

    func testARealGetClockReplyYieldsItsBodyUpToTheTrailer() {
        let frame = bytes("aa011400010021b124230be80146aaaf6a0000000000000014cbbb6c")
        XCTAssertEqual(FrameRouter.commandResponsePayload(in: frame),
                       [0x46, 0xaa, 0xaf, 0x6a, 0, 0, 0, 0, 0, 0, 0])
        XCTAssertEqual(FrameRouter.commandResponsePayloadHex(in: frame), "46 aa af 6a 00 00 00 00 00 00 00")
    }

    func testARealSetClockReplyYieldsItsPadding() {
        let frame = bytes("aa010c000100271124220ae701000000bcc4efc3")
        XCTAssertEqual(FrameRouter.commandResponsePayload(in: frame), [0, 0, 0])
    }

    func testAFrameShorterThanItsDeclaredLengthHasNoPayload() {
        let frame = bytes("aa011400010021b124230be80146aaaf6a0000000000000014cbbb6c")
        XCTAssertNil(FrameRouter.commandResponsePayload(in: Array(frame.dropLast(5))))
        XCTAssertNil(FrameRouter.commandResponsePayload(in: [0xAA, 0x01, 0x14]))
    }
}
