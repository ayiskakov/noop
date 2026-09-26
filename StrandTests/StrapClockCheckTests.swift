import XCTest
import WhoopProtocol
@testable import Strand

/// W06-050's app-layer half (W06-073): what `BLEManager` does with each clock-check outcome. `StrapClockTests`
/// pins the verdicts; these pin that a verdict needing no set sends none, that the connect handshake waits for
/// the check, that a set settles it, that the timeout settles only the link the check began on (W06-085), and
/// that a first read answered over a round trip too long to judge is read once more (W06-084).
/// The manager has no strap, so `send` writes nothing and logs "send(<label>) ignored" instead, which is how a
/// test sees that a SET_CLOCK was asked for.
@MainActor
final class StrapClockCheckTests: XCTestCase {
    private var live: LiveState!
    private var manager: BLEManager!

    override func setUp() async throws {
        live = LiveState()
        manager = BLEManager(state: live, deviceId: "rig-\(UUID().uuidString)", collector: nil)
    }

    private var now: Double { Date().timeIntervalSince1970 }

    /// A GET_CLOCK COMMAND_RESPONSE answering request `origin` with the strap reading `seconds`.
    private func clockReply(origin: UInt8, seconds: UInt32) -> [UInt8] {
        let s = (0..<4).map { UInt8((seconds >> (8 * $0)) & 0xFF) }
        return puffinCommandFrame(cmd: 11, seq: 0x40, payload: [origin, StrapClock.resultSuccess] + s + [0, 0, 0],
                                  type: 36, header: [0x01, 0x00])
    }

    private func lines(containing needle: String) -> [String] { live.log.filter { $0.contains(needle) } }
    private var setClockAsks: Int { lines(containing: "send(Set Clock)").count }
    private var handshakeDoneLines: Int { lines(containing: "connect handshake done").count }

    func testAReadingInSyncSendsNoSetAndSettlesTheHandshake() {
        manager.strapClockCheck.beginRead(sequence: 7, at: BLEManager.monotonicSeconds())
        manager.handleStrapClockReply(clockReply(origin: 7, seconds: UInt32(now)))
        XCTAssertEqual(setClockAsks, 0, live.log.joined(separator: "\n"))
        XCTAssertTrue(live.historyReady)
        XCTAssertEqual(handshakeDoneLines, 1)
    }

    func testAReadingOffSetsTheClockAndThenSettles() {
        manager.strapClockCheck.beginRead(sequence: 7, at: BLEManager.monotonicSeconds())
        manager.handleStrapClockReply(clockReply(origin: 7, seconds: UInt32(now) - 100))
        XCTAssertEqual(setClockAsks, 1, live.log.joined(separator: "\n"))
        XCTAssertTrue(live.historyReady)
        XCTAssertEqual(handshakeDoneLines, 1)
    }

    func testAnInvalidReadingSetsTheClock() {
        manager.strapClockCheck.beginRead(sequence: 7, at: BLEManager.monotonicSeconds())
        manager.handleStrapClockReply(clockReply(origin: 7, seconds: 60))
        XCTAssertEqual(setClockAsks, 1, live.log.joined(separator: "\n"))
        XCTAssertTrue(live.historyReady)
    }

    func testAReplyToNoReadInFlightChangesNothing() {
        manager.strapClockCheck.beginRead(sequence: 7, at: BLEManager.monotonicSeconds())
        manager.handleStrapClockReply(clockReply(origin: 8, seconds: UInt32(now) - 100))
        XCTAssertEqual(setClockAsks, 0)
        XCTAssertFalse(live.historyReady)
    }

    /// W06-079: the in-sync verdict and the "sent" line are per-connect readouts, so a default log leaves them
    /// out; a verdict that sets is rare evidence and is logged either way.
    func testRoutineClockLinesNeedTestCentreAndASetIsAlwaysLogged() {
        TestCentre.deactivate(.connection)
        manager.strapClockCheck.beginRead(sequence: 7, at: BLEManager.monotonicSeconds())
        manager.handleStrapClockReply(clockReply(origin: 7, seconds: UInt32(now)))
        XCTAssertEqual(lines(containing: "not set").count, 0, live.log.joined(separator: "\n"))

        TestCentre.activate(.connection)
        defer { TestCentre.deactivate(.connection) }
        let second = BLEManager(state: live, deviceId: "rig-\(UUID().uuidString)", collector: nil)
        second.strapClockCheck.beginRead(sequence: 7, at: BLEManager.monotonicSeconds())
        second.handleStrapClockReply(clockReply(origin: 7, seconds: UInt32(now)))
        XCTAssertEqual(lines(containing: "within 2 s, not set").count, 1, live.log.joined(separator: "\n"))
    }

    func testAVerdictThatSetsIsLoggedWithoutTestCentre() {
        TestCentre.deactivate(.connection)
        manager.strapClockCheck.beginRead(sequence: 7, at: BLEManager.monotonicSeconds())
        manager.handleStrapClockReply(clockReply(origin: 7, seconds: UInt32(now) - 100))
        XCTAssertEqual(lines(containing: "more than 2 s off, setting it").count, 1, live.log.joined(separator: "\n"))
    }

    func testTheHandshakeWaitsForTheCheck() {
        manager.beginStrapClockCheck()
        XCTAssertFalse(live.historyReady, live.log.joined(separator: "\n"))
        XCTAssertEqual(handshakeDoneLines, 0)
    }

    /// The link the check began on is still up, so the strap is set without a reading, as every connect did
    /// before W06-050, and the handshake settles. `link` stands in for a connected peripheral.
    func testTheTimeoutOnTheSameLinkSetsTheClockWithoutAReadingAndSettles() {
        let token = manager.beginStrapClockCheck()
        manager.strapClockCheckTimedOut(token: token, link: .same)
        XCTAssertEqual(setClockAsks, 1, live.log.joined(separator: "\n"))
        XCTAssertEqual(lines(containing: "setting the clock without a reading").count, 1)
        XCTAssertTrue(live.historyReady)
        XCTAssertEqual(handshakeDoneLines, 1)
    }

    /// W06-085: a link that came up after a power-off inherited the session flag and skipped the handshake, so
    /// the timeout gives it a check of its own rather than settling the dead link.
    func testTheTimeoutWithANewerLinkUpChecksThatLinkInstead() {
        manager.whoop5SessionStarted = true
        let token = manager.beginStrapClockCheck()
        manager.strapClockCheckTimedOut(token: token, link: .newer)
        XCTAssertEqual(lines(containing: "reading the clock on the link that replaced it").count, 1,
                       live.log.joined(separator: "\n"))
        XCTAssertEqual(lines(containing: "GET_CLOCK was not sent").count, 2)   // the first check's, then the new one's
        XCTAssertFalse(manager.strapClockCheck.settled, "a fresh check waits on the newer link")
        XCTAssertEqual(setClockAsks, 0)
        XCTAssertFalse(live.historyReady)
        XCTAssertEqual(live.connectSettled, 0)
        XCTAssertTrue(manager.whoop5SessionStarted, "the newer link's handshake must not run again mid-link")
    }

    /// W06-069: a Bluetooth power-off leaves `connected` set (W06-083), so the timeout must ask the link itself
    /// rather than claim a set that `send` will drop. W06-085: and settle nothing on the dead link. Settling
    /// there spent the alarm re-arm on it and left the reconnect, which inherits the session flag and skips the
    /// handshake, with no clock check; clearing the flag lets the next link run the handshake, check included.
    func testTheTimeoutOnALinkThatIsGoneSettlesNothingAndLetsTheNextLinkRunTheHandshake() {
        live.connected = true   // what a power-off leaves behind: the flag, with no connected peripheral
        manager.whoop5SessionStarted = true   // as the handshake that began the check left it
        let token = manager.beginStrapClockCheck()
        manager.strapClockCheckTimedOut(token: token)
        XCTAssertEqual(setClockAsks, 0, live.log.joined(separator: "\n"))
        XCTAssertEqual(lines(containing: "setting the clock without a reading").count, 0)
        XCTAssertEqual(lines(containing: "the handshake, clock check included, runs again on the next link").count, 1)
        XCTAssertFalse(live.historyReady)
        XCTAssertEqual(handshakeDoneLines, 0)
        XCTAssertEqual(live.connectSettled, 0)
        XCTAssertFalse(manager.whoop5SessionStarted)
    }

    func testTheTimeoutOfAReplacedCheckDoesNothing() {
        let stale = manager.beginStrapClockCheck()
        manager.beginStrapClockCheck()
        manager.strapClockCheckTimedOut(token: stale)
        XCTAssertFalse(live.historyReady)
        XCTAssertEqual(handshakeDoneLines, 0)
    }

    func testTheTimeoutAfterAReplyDoesNothing() {
        let token = manager.beginStrapClockCheck()
        manager.strapClockCheck.beginRead(sequence: 7, at: BLEManager.monotonicSeconds())
        manager.handleStrapClockReply(clockReply(origin: 7, seconds: UInt32(now)))
        manager.strapClockCheckTimedOut(token: token)
        XCTAssertEqual(setClockAsks, 0, live.log.joined(separator: "\n"))
        XCTAssertEqual(handshakeDoneLines, 1)
    }

    /// W06-084: on a restored link the first read waits behind the notify re-subscribe writes, and over that
    /// round trip even a clock in sync reads unresolved, so the check reads once more before anything settles.
    func testASlowUnresolvedReadIsReadAgainBeforeTheHandshakeSettles() {
        manager.strapClockCheck.beginRead(sequence: 7, at: BLEManager.monotonicSeconds() - 4)   // sent 4 s ago
        manager.handleStrapClockReply(clockReply(origin: 7, seconds: UInt32(now)))
        XCTAssertEqual(lines(containing: "the second GET_CLOCK was not sent").count, 1, live.log.joined(separator: "\n"))
        XCTAssertFalse(live.historyReady)
        XCTAssertEqual(handshakeDoneLines, 0)
        // This manager has no strap, so the second read goes in flight by hand; its reply decides.
        manager.strapClockCheck.beginRead(sequence: 8, at: BLEManager.monotonicSeconds())
        manager.handleStrapClockReply(clockReply(origin: 8, seconds: UInt32(now)))
        XCTAssertEqual(setClockAsks, 0, live.log.joined(separator: "\n"))
        XCTAssertTrue(live.historyReady)
        XCTAssertEqual(handshakeDoneLines, 1)
    }

    /// W06-084: a strap 4 s behind reads unresolved over a restored link's round trip; the second read shows it
    /// off, and it is set.
    func testAStrapFourSecondsBehindOnASlowLinkIsSetAfterTheSecondRead() {
        manager.strapClockCheck.beginRead(sequence: 7, at: BLEManager.monotonicSeconds() - 4)
        manager.handleStrapClockReply(clockReply(origin: 7, seconds: UInt32(now) - 4))
        XCTAssertEqual(setClockAsks, 0, live.log.joined(separator: "\n"))
        manager.strapClockCheck.beginRead(sequence: 8, at: BLEManager.monotonicSeconds())
        manager.handleStrapClockReply(clockReply(origin: 8, seconds: UInt32(now) - 4))
        XCTAssertEqual(setClockAsks, 1, live.log.joined(separator: "\n"))
        XCTAssertTrue(live.historyReady)
    }

    /// W06-084: an unanswered second read leaves the first reading standing, and that reading did not show the
    /// clock off, so the timeout settles without the set it makes when no reading came at all.
    func testAnUnansweredSecondReadLeavesTheFirstReadingStanding() {
        manager.strapClockCheck.beginRead(sequence: 7, at: BLEManager.monotonicSeconds() - 4)
        manager.handleStrapClockReply(clockReply(origin: 7, seconds: UInt32(now)))
        manager.strapClockCheckTimedOut(token: manager.strapClockCheckToken, link: .same)
        XCTAssertEqual(setClockAsks, 0, live.log.joined(separator: "\n"))
        XCTAssertEqual(lines(containing: "the first reading stands").count, 1)
        XCTAssertTrue(live.historyReady)
        XCTAssertEqual(handshakeDoneLines, 1)
    }
}

/// W06-071: the first 5/MG offload keeps the hardware-validated 1.5 s after a SET_CLOCK, however late the set.
final class FirstOffloadDelayTests: XCTestCase {
    func testASetGetsTheFullSettleWhateverTheHandshakeAge() {
        XCTAssertEqual(BLEManager.firstOffloadDelay(sinceHandshake: 10.2, setJustSent: true), 1.5)
        XCTAssertEqual(BLEManager.firstOffloadDelay(sinceHandshake: 0.1, setJustSent: true), 1.5)
    }

    func testWithoutASetOnlyWhatRemainsSinceTheHandshake() {
        XCTAssertEqual(BLEManager.firstOffloadDelay(sinceHandshake: 0.5, setJustSent: false), 1.0, accuracy: 1e-9)
        XCTAssertEqual(BLEManager.firstOffloadDelay(sinceHandshake: 4.0, setJustSent: false), 0)
        XCTAssertEqual(BLEManager.firstOffloadDelay(sinceHandshake: nil, setJustSent: false), 1.5)
    }
}
