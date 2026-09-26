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

    // MARK: - W06-066: the #1303 hello probe W06-065 revived

    /// A GET_HELLO reply shaped like the real 5/MG block: origin sequence and result, then a body in which
    /// the decoder's offset 16 (frame byte 27) holds the device name and a serial-shaped run sits later.
    /// Synthetic, so no real name, serial or session token enters the repository.
    private func helloReply(result: UInt8) -> [UInt8] {
        var body = [UInt8](repeating: 0, count: 110)
        if result == 1 {
            for (i, c) in "WHOOP-FAKE01".utf8.enumerated() { body[14 + i] = c }
            for (i, c) in "3A1B2405003655".utf8.enumerated() { body[40 + i] = c }
        }
        return puffinCommandFrame(cmd: 145, seq: 0x6d, payload: [0x01, result] + body, type: 36,
                                  header: [0x01, 0x00])
    }

    private func probeLines(after frame: [UInt8]) -> [String] {
        TestCentre.activate(.connection)
        defer { TestCentre.deactivate(.connection) }
        let live = LiveState()
        FrameRouter(state: live).handle(frame: frame)
        return live.log.filter { $0.contains("#1303") }
    }

    func testTheHelloProbeLabelsTheNameWhereTheDecoderReadsIt() {
        let frame = helloReply(result: 1)
        XCTAssertEqual(parseFrame(frame, family: .whoop5).parsed["device_name"]?.stringValue, "WHOOP-FAKE01",
                       "the fixture puts the name where the decoder reads it")
        let lines = probeLines(after: frame)
        XCTAssertEqual(lines.count, 1)
        XCTAssertTrue(lines.first?.contains("off=14 len=12 mixed (device name, already decoded)") == true,
                      lines.first ?? "nil")
        // W06-092: the serial-shaped run is quoted by its first three characters only.
        XCTAssertTrue(lines.first?.contains(#"off=40 len=14 alnum "3A1…""#) == true, lines.first ?? "nil")
        XCTAssertFalse(lines.first?.contains("3A1B2405003655") == true, lines.first ?? "nil")
    }

    func testTheHelloProbeIgnoresThePendingAcknowledgement() {
        XCTAssertEqual(probeLines(after: helloReply(result: 2)), [],
                       "a PENDING reply carries no block, so it must not report one without a serial")
    }

    func testAFrameShorterThanItsDeclaredLengthHasNoPayload() {
        let frame = bytes("aa011400010021b124230be80146aaaf6a0000000000000014cbbb6c")
        XCTAssertNil(FrameRouter.commandResponsePayload(in: Array(frame.dropLast(5))))
        XCTAssertNil(FrameRouter.commandResponsePayload(in: [0xAA, 0x01, 0x14]))
    }

    // MARK: - W06-095: a clock reply states a reading only when it carries one

    func testAFailedClockReplyPrintsNoReading() {
        let frame = puffinCommandFrame(cmd: 11, seq: 0x40, payload: [0x07, 0x00] + [UInt8](repeating: 0, count: 11),
                                       type: 36, header: [0x01, 0x00])
        let live = LiveState()
        FrameRouter(state: live).handle(frame: frame)
        let clock = live.log.filter { $0.contains("clock: GET_CLOCK") }
        XCTAssertEqual(clock.count, 1, live.log.joined(separator: "\n"))
        XCTAssertFalse(clock.first?.contains("strap=") == true, clock.first ?? "nil")
    }

    // MARK: - W06-100: the routine GET_CLOCK reading is a Test Centre readout

    /// Runs `body` with Test Centre's connection domain set as given and the master flag, which implies every
    /// domain, off. Both keys live in the test host's defaults, so they are restored afterwards.
    private func withTestCentreConnection(_ on: Bool, _ body: () -> Void) {
        let keys = ["testcentre.active.connection", "testcentre.active.master"]
        let saved = keys.map { UserDefaults.standard.object(forKey: $0) }
        defer {
            for (key, value) in zip(keys, saved) {
                if let value { UserDefaults.standard.set(value, forKey: key) } else { UserDefaults.standard.removeObject(forKey: key) }
            }
        }
        UserDefaults.standard.removeObject(forKey: keys[1])
        if on { TestCentre.activate(.connection) } else { TestCentre.deactivate(.connection) }
        body()
    }

    private func clockLines(after frame: [UInt8]) -> [String] {
        let live = LiveState()
        FrameRouter(state: live).handle(frame: frame)
        return live.log.filter { $0.contains("clock: ") }
    }

    func testARoutineClockReadingIsATestCentreReadout() {
        let reading = puffinCommandFrame(cmd: 11, seq: 0x40,
                                         payload: [0x07, 0x01, 0x80, 0x0b, 0xb0, 0x6a] + [UInt8](repeating: 0, count: 7),
                                         type: 36, header: [0x01, 0x00])
        withTestCentreConnection(false) { XCTAssertEqual(clockLines(after: reading), []) }
        withTestCentreConnection(true) { XCTAssertEqual(clockLines(after: reading).count, 1) }
    }

    /// Rare evidence stays in a default log: every SET_CLOCK reply (W06-079), and any clock reply without a reading.
    func testASetClockReplyAndAReplyWithoutAReadingStayAlwaysOn() {
        withTestCentreConnection(false) {
            XCTAssertEqual(clockLines(after: bytes("aa010c000100271124220ae701000000bcc4efc3")).count, 1)
            let failed = puffinCommandFrame(cmd: 11, seq: 0x40, payload: [0x07, 0x00] + [UInt8](repeating: 0, count: 11),
                                            type: 36, header: [0x01, 0x00])
            XCTAssertEqual(clockLines(after: failed).count, 1)
        }
    }
}
