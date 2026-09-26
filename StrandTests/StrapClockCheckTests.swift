import XCTest
import WhoopProtocol
@testable import Strand

/// W06-050's app-layer half (W06-073): what `BLEManager` does with each clock-check outcome. `StrapClockTests`
/// pins the verdicts; these pin that a verdict needing no set sends none, that the connect handshake waits for
/// the check, and that a set and the timeout both settle it. The manager has no strap, so `send` writes
/// nothing and logs "send(<label>) ignored" instead, which is how a test sees that a SET_CLOCK was asked for.
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

    func testTheTimeoutSettlesTheHandshake() {
        let token = manager.beginStrapClockCheck()
        manager.strapClockCheckTimedOut(token: token)
        XCTAssertTrue(live.historyReady, live.log.joined(separator: "\n"))
        XCTAssertEqual(handshakeDoneLines, 1)
    }

    /// W06-069: a Bluetooth power-off leaves `connected` set (W06-083), so the timeout must ask the link itself
    /// rather than claim a set that `send` will drop. The handshake still settles (W06-072).
    func testTheTimeoutOnALinkThatIsGoneSetsNothingAndSaysSo() {
        live.connected = true   // what a power-off leaves behind: the flag, with no connected peripheral
        let token = manager.beginStrapClockCheck()
        manager.strapClockCheckTimedOut(token: token)
        XCTAssertEqual(setClockAsks, 0, live.log.joined(separator: "\n"))
        XCTAssertEqual(lines(containing: "setting the clock without a reading").count, 0)
        XCTAssertEqual(lines(containing: "is gone — the clock is neither read nor set").count, 1)
        XCTAssertTrue(live.historyReady)
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
