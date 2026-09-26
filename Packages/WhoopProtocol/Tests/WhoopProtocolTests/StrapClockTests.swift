import XCTest
@testable import WhoopProtocol

/// W06-050 and W06-001: the GET_CLOCK reply decode and the read-first clock policy. The three GET_CLOCK
/// frames and the SET_CLOCK frame are real replies from one WHOOP MG on firmware 50.39.1.0; the failure and
/// pending replies are built with `puffinCommandFrame`, since no strap log holds one.
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

    // MARK: judge

    private let t0 = 1_790_000_000.25   // phone time the read was sent; each reply time is t0 + its round trip

    func testAClockWithinTheThresholdIsNotSet() {
        let r = StrapClock.Reading(originSequence: 1, result: 1, seconds: 1_790_000_000)
        let v = StrapClock.judge(r, receivedAt: t0 + 0.5, roundTrip: 0.5)
        XCTAssertEqual(v, .inSync(seconds: 1_790_000_000, low: -0.75, high: 0.75))
        XCTAssertFalse(v.needsSet)
    }

    func testAClockProvablyBehindIsSet() {
        // Four seconds behind, answered quickly: the whole range lies past −2 s.
        let r = StrapClock.Reading(originSequence: 1, result: 1, seconds: 1_789_999_996)
        let v = StrapClock.judge(r, receivedAt: t0 + 0.5, roundTrip: 0.5)
        XCTAssertEqual(v, .off(seconds: 1_789_999_996, low: -4.75, high: -3.25))
        XCTAssertTrue(v.needsSet)
    }

    func testAClockProvablyAheadIsSet() {
        let r = StrapClock.Reading(originSequence: 1, result: 1, seconds: 1_790_000_005)
        XCTAssertEqual(StrapClock.judge(r, receivedAt: t0 + 1, roundTrip: 1),
                       .off(seconds: 1_790_000_005, low: 3.75, high: 5.75))
    }

    func testALongRoundTripNeverSetsByItself() {
        // The relaunch shape: the reply came four seconds after the request and reads the second it was
        // sent. The strap may have read its clock at once (in sync) or four seconds later (four behind).
        let r = StrapClock.Reading(originSequence: 1, result: 1, seconds: 1_790_000_000)
        let v = StrapClock.judge(r, receivedAt: t0 + 4, roundTrip: 4)
        XCTAssertEqual(v, .unresolved(seconds: 1_790_000_000, low: -4.25, high: 0.75))
        XCTAssertFalse(v.needsSet)
    }

    func testAnExactlyTwoSecondRangeEdgeIsNotOff() {
        // high == −2 is not past the threshold.
        let r = StrapClock.Reading(originSequence: 1, result: 1, seconds: 1_789_999_997)
        XCTAssertFalse(StrapClock.judge(r, receivedAt: 1_790_000_000.5, roundTrip: 0.5).needsSet)
        let r2 = StrapClock.Reading(originSequence: 1, result: 1, seconds: 1_789_999_996)
        XCTAssertTrue(StrapClock.judge(r2, receivedAt: 1_790_000_000.5, roundTrip: 0.5).needsSet)
    }

    func testNoWallClockIsSetWhateverTheResult() {
        for s: UInt32 in [0, 86_400, StrapClock.validityFloor] {
            let v = StrapClock.judge(.init(originSequence: 1, result: 1, seconds: s), receivedAt: t0, roundTrip: 0)
            XCTAssertEqual(v, .invalid(seconds: s))
            XCTAssertTrue(v.needsSet)
        }
        // One second past the floor is a wall clock, and this one is decades off.
        let past = StrapClock.judge(.init(originSequence: 1, result: 1, seconds: StrapClock.validityFloor + 1),
                                    receivedAt: t0, roundTrip: 0)
        guard case .off = past else { return XCTFail("\(past)") }
    }

    func testAReplyWithoutAReadingIsSet() {
        let refused = StrapClock.judge(.init(originSequence: 1, result: 3, seconds: 1_790_000_000),
                                       receivedAt: t0, roundTrip: 0)
        XCTAssertEqual(refused, .unread(result: 3))
        XCTAssertEqual(StrapClock.judge(.init(originSequence: 1, result: 1, seconds: nil), receivedAt: t0, roundTrip: 0),
                       .unread(result: 1))
        XCTAssertTrue(refused.needsSet)
    }

    /// W06-074: the phone runs 4 s fast and is stepped back to the right time during a 0.25 s read of a strap
    /// that is right. With the send time taken from the wall clock (T + 4) the range was −4…−3 s and the strap
    /// was set; from the reply's wall time and the monotonic round trip it is in sync.
    func testAPhoneClockSteppedBackDuringTheReadDoesNotSetACorrectStrap() {
        let T = 1_790_000_000.0
        let r = StrapClock.Reading(originSequence: 1, result: 1, seconds: 1_790_000_000)
        XCTAssertEqual(StrapClock.judge(r, receivedAt: T + 0.25, roundTrip: 0.25),
                       .inSync(seconds: 1_790_000_000, low: -0.25, high: 1.0))
    }

    func testANegativeRoundTripCountsAsZero() {
        let r = StrapClock.Reading(originSequence: 1, result: 1, seconds: 1_790_000_000)
        XCTAssertEqual(StrapClock.judge(r, receivedAt: t0, roundTrip: -3),
                       StrapClock.judge(r, receivedAt: t0, roundTrip: 0))
    }

    // MARK: Check

    private let now = 1_790_000_000.0
    private func reading(_ origin: UInt8, result: UInt8 = 1, seconds: UInt32? = 1_790_000_000) -> StrapClock.Reading {
        .init(originSequence: origin, result: result, seconds: seconds)
    }

    func testAnInSyncReadSettlesWithoutASet() {
        var check = StrapClock.Check()
        check.beginRead(sequence: 9, at: now)
        guard case let .settle(v, rt) = check.receive(reading(9), at: now + 0.5, wallClock: now + 0.5) else {
            return XCTFail()
        }
        XCTAssertFalse(v.needsSet)
        XCTAssertEqual(rt, 0.5)
        XCTAssertTrue(check.settled)
        XCTAssertFalse(check.expire(), "a settled check must not expire into a blind set")
    }

    func testAnOffReadAsksForASetAndItsReadbackIsReportedNotJudged() {
        var check = StrapClock.Check()
        check.beginRead(sequence: 9, at: now)
        guard case let .set(v, _) = check.receive(reading(9, seconds: 1_789_999_990), at: now + 0.2,
                                                  wallClock: now + 0.2) else {
            return XCTFail()
        }
        XCTAssertTrue(v.needsSet)
        check.beginReadback(sequence: 11, at: now + 0.3)
        XCTAssertEqual(check.receive(reading(11, seconds: 1_790_000_000), at: now + 1.3, wallClock: now + 1.3),
                       .readback(reading(11, seconds: 1_790_000_000), roundTrip: 1.0))
        // A second copy of the readback answers nothing in flight.
        XCTAssertEqual(check.receive(reading(11), at: now + 2, wallClock: now + 2), .notOurs)
    }

    func testPendingWaitsForTheAnswer() {
        var check = StrapClock.Check()
        check.beginRead(sequence: 9, at: now)
        XCTAssertEqual(check.receive(reading(9, result: 2, seconds: nil), at: now + 0.1, wallClock: now + 0.1),
                       .pending)
        XCTAssertFalse(check.settled)
        guard case .settle = check.receive(reading(9), at: now + 0.6, wallClock: now + 0.6) else { return XCTFail() }
        check.beginReadback(sequence: 10, at: now + 1)
        XCTAssertEqual(check.receive(reading(10, result: 2, seconds: nil), at: now + 1.1, wallClock: now + 1.1),
                       .pending)
    }

    /// The round trip comes from the monotonic clock and the reading is judged against the wall clock at the
    /// reply, so the two may sit on different bases (W06-074).
    func testTheVerdictUsesTheWallClockAtTheReplyAndTheMonotonicRoundTrip() {
        var check = StrapClock.Check()
        check.beginRead(sequence: 9, at: 500)   // seconds since some monotonic origin
        guard case let .settle(v, rt) = check.receive(reading(9), at: 500.25, wallClock: now + 0.25) else {
            return XCTFail()
        }
        XCTAssertEqual(rt, 0.25)
        XCTAssertEqual(v, .inSync(seconds: 1_790_000_000, low: -0.25, high: 1.0))
    }

    func testAReplyToAnotherRequestIsNotOurs() {
        var check = StrapClock.Check()
        check.beginRead(sequence: 9, at: now)
        XCTAssertEqual(check.receive(reading(8), at: now + 0.2, wallClock: now + 0.2), .notOurs)
        XCTAssertFalse(check.settled)
    }

    func testAnUnansweredReadExpiresOnceAndALateReplyChangesNothing() {
        var check = StrapClock.Check()
        check.beginRead(sequence: 9, at: now)
        XCTAssertTrue(check.expire())
        XCTAssertFalse(check.expire())
        XCTAssertEqual(check.receive(reading(9, seconds: 1_789_000_000), at: now + 12, wallClock: now + 12),
                       .notOurs)
        check.beginRead(sequence: 12, at: now + 13)
        XCTAssertNil(check.read, "a settled check starts no second read")
    }

    func testAReadThatNeverWentOutStillExpires() {
        var check = StrapClock.Check()
        XCTAssertTrue(check.expire())
    }

    // MARK: describe

    func testLogLinesStateTheReadingAndTheRange() {
        XCTAssertEqual(StrapClock.describe(.inSync(seconds: 1_790_000_000, low: -0.65, high: 0.75), roundTrip: 0.4),
                       "strap clock reads 1790000000, -0.7…+0.8 s from the phone over a 0.4 s round trip — "
                       + "within 2 s, not set")
        XCTAssertEqual(StrapClock.describe(.unresolved(seconds: 1_790_000_000, low: -4.25, high: 0.75), roundTrip: 4),
                       "strap clock reads 1790000000, -4.2…+0.8 s from the phone over a 4.0 s round trip — "
                       + "that does not show it more than 2 s off, not set")
        XCTAssertEqual(StrapClock.describe(.off(seconds: 1_789_999_996, low: -4.75, high: -3.25), roundTrip: 0.5),
                       "strap clock reads 1789999996, -4.8…-3.2 s from the phone over a 0.5 s round trip — "
                       + "more than 2 s off, setting it")
        XCTAssertEqual(StrapClock.describe(.invalid(seconds: 0), roundTrip: 0.1),
                       "strap clock reads 0, not a wall clock (at or below 1293840001) — setting it")
        XCTAssertEqual(StrapClock.describe(.unread(result: 3), roundTrip: 0.1),
                       "GET_CLOCK answered result 3 with no reading — setting the clock")
    }
}
