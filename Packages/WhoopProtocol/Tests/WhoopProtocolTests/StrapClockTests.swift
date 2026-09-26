import XCTest
@testable import WhoopProtocol

/// W06-001: the GET_CLOCK reply decode. The three GET_CLOCK frames and the SET_CLOCK frame are real replies
/// from one WHOOP MG on firmware 50.39.1.0; the failure reply is built with `puffinCommandFrame`, since no
/// strap log holds one.
final class StrapClockTests: XCTestCase {

    private func bytes(_ s: String) -> [UInt8] {
        stride(from: 0, to: s.count, by: 2).map { i in
            let a = s.index(s.startIndex, offsetBy: i)
            return UInt8(s[a...s.index(a, offsetBy: 1)], radix: 16)!
        }
    }

    /// A format-1 COMMAND_RESPONSE with the envelope header bytes the strap sends (01 00).
    private func reply(cmd: UInt8, origin: UInt8, result: UInt8, body: [UInt8] = []) -> [UInt8] {
        puffinCommandFrame(cmd: cmd, seq: 0x40, payload: [origin, result] + body, type: 36, header: [0x01, 0x00])
    }

    private func u32(_ v: UInt32) -> [UInt8] { (0..<4).map { UInt8((v >> (8 * $0)) & 0xFF) } }

    // MARK: decodeReply

    func testRealGetClockRepliesDecodeTheirSecondsAndOrigin() {
        let cases: [(String, UInt8, UInt32)] = [
            ("aa011400010021b124230be80146aaaf6a0000000000000014cbbb6c", 0xe8, 1_789_897_286),
            ("aa011400010021b124700b020194b5b66a0000000000000005a36ce6", 0x02, 1_790_358_932),
            ("aa011400010021b124800b0201bab6b66a00000000000000c0966a91", 0x02, 1_790_359_226),
        ]
        for (hex, origin, seconds) in cases {
            let frame = bytes(hex)
            XCTAssertTrue(verifyFrame(frame, family: .whoop5).ok, hex)
            XCTAssertEqual(StrapClock.decodeReply(frame),
                           StrapClock.Reading(originSequence: origin, result: 1, seconds: seconds), hex)
        }
    }

    func testOtherRepliesAreNotAClockReading() {
        let setClockReply = bytes("aa010c000100271124220ae701000000bcc4efc3")
        XCTAssertTrue(verifyFrame(setClockReply, family: .whoop5).ok)
        XCTAssertNil(StrapClock.decodeReply(setClockReply))
        // Command 11 in a COMMAND frame (type 35) is our own request, not a reply.
        XCTAssertNil(StrapClock.decodeReply(puffinCommandFrame(cmd: 11, seq: 3, payload: [])))
        XCTAssertNil(StrapClock.decodeReply([0xAA, 0x01]))
    }

    func testAFailureReplyWithNoBodyDecodesWithoutSeconds() {
        let frame = reply(cmd: 11, origin: 7, result: 3)
        XCTAssertTrue(verifyFrame(frame, family: .whoop5).ok)
        XCTAssertEqual(StrapClock.decodeReply(frame), StrapClock.Reading(originSequence: 7, result: 3, seconds: nil))
    }

    func testTheBodyEndsAtTheDeclaredLengthNotTheBufferEnd() {
        // Extra bytes after the frame (a reassembly overrun) must not be read as seconds.
        let frame = reply(cmd: 11, origin: 7, result: 1) + u32(1_790_000_000)
        XCTAssertEqual(StrapClock.decodeReply(frame)?.seconds, nil)
    }
}
