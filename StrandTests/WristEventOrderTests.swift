import XCTest
@testable import Strand

/// W06-121 and W06-115: the wear state follows the NEWEST wrist event by the strap's own timestamp, whichever path
/// delivers it. A strap put back on while unlinked sends its WRIST_ON only as history, outside the live window, and
/// `worn` used to stay false after the reconnect (W06-121); an offload replaying an older event inside the window
/// used to flip `worn` and the per-link record back (W06-115). A live event from `handle` always applies, since it is
/// the strap's current state even after its clock stepped back. History moves `worn` only: the wrist Shortcuts and
/// macOS auto-lock (`onWristChange`) are for a change happening now, and W06-109's per-link record is live-only.
/// W06-145: history moves `worn` only back to on, the documented default. An offload synced in pieces can stop on a
/// WRIST_OFF whose WRIST_ON it has not delivered yet, and no live event would correct that on a worn strap.
/// W06-154: history can take back a WRIST_ON it applied itself, until a live event takes over. W06-158, W06-159:
/// another physical strap starts the order and the wear state afresh.
@MainActor
final class WristEventOrderTests: XCTestCase {
    /// The captured WHOOP 5 DOUBLE_TAP frame of `FrameRouterDoubleTapDedupTests` with its event byte set to
    /// WRIST_OFF(10) or WRIST_ON(9), `event_timestamp` (bytes 12..<16) set to `t0` plus the key's seconds, and the
    /// payload CRC32 (bytes 8..<20) recomputed with zlib.
    private static let t0 = 1_780_910_464
    private static let off: [Int: String] = [
        0: "aa0110000100208130340a008089266a3d2a00004a18349b",
        10: "aa0110000100208130340a008a89266a3d2a00008204f40a",
        600: "aa0110000100208130340a00d88b266a3d2a000010e1688a",
        900: "aa0110000100208130340a00048d266a3d2a000079b70ab8",
    ]
    private static let on: [Int: String] = [
        0: "aa01100001002081303409008089266a3d2a000049a30370",
        10: "aa01100001002081303409008a89266a3d2a000081bfc3e1",
        600: "aa0110000100208130340900d88b266a3d2a0000135a5f61",
        900: "aa0110000100208130340900048d266a3d2a00007a0c3d53",
    ]

    private var live: LiveState!
    private var router: FrameRouter!
    private var callbacks: [Bool] = []

    override func setUp() async throws {
        live = LiveState()
        router = FrameRouter(state: live)
        router.family = .whoop5
        callbacks = []
        live.onWristChange = { [weak self] worn in self?.callbacks.append(worn) }
    }

    override func tearDown() async throws {
        router = nil
        live = nil
    }

    private func bytes(_ hex: String?) -> [UInt8] {
        let hex = hex!
        return stride(from: 0, to: hex.count, by: 2).compactMap {
            let i = hex.index(hex.startIndex, offsetBy: $0)
            return UInt8(hex[i..<hex.index(i, offsetBy: 2)], radix: 16)
        }
    }

    /// An offload frame, judged against the strap's clock-now `t0 + at`.
    private func offload(_ hex: String?, at: Int) {
        router.dispatchLiveGestureIfFresh(frame: bytes(hex), now: Self.t0 + at)
    }

    private func lines(containing needle: String) -> [String] { live.log.filter { $0.contains(needle) } }

    /// W06-121: taken off on the link, put back on while unlinked; the reconnect's offload carries the WRIST_ON.
    func testAWristOnThatArrivesOnlyAsHistorySetsTheWearState() {
        router.handle(frame: bytes(Self.off[0]))
        XCTAssertFalse(live.worn)
        offload(Self.on[600], at: 900)
        XCTAssertTrue(live.worn, live.log.joined(separator: "\n"))
        XCTAssertEqual(callbacks, [false], "history must not run the wrist Shortcuts")
        XCTAssertEqual(live.wristEventThisLink, false, "the per-link record is live-only (W06-109)")
        XCTAssertEqual(lines(containing: "Wrist: WRIST_ON reached through a sync").count, 1)
    }

    /// W06-115: off, then on, both live; the offload then replays the WRIST_OFF inside the live window.
    func testAReplayedOlderWristOffInsideTheWindowChangesNothing() {
        router.handle(frame: bytes(Self.off[0]))
        router.handle(frame: bytes(Self.on[10]))
        offload(Self.off[0], at: 20)
        XCTAssertTrue(live.worn)
        XCTAssertEqual(live.wristEventThisLink, true)
        XCTAssertEqual(callbacks, [false, true])
    }

    func testAnOlderEventFromHistoryChangesNothing() {
        router.handle(frame: bytes(Self.on[600]))
        offload(Self.off[0], at: 900)
        XCTAssertTrue(live.worn)
        XCTAssertEqual(lines(containing: "reached through a sync").count, 0)
    }

    /// W06-145: a WRIST_OFF from history never turns the wear state off; the piece of history synced so far may
    /// end on it with the WRIST_ON that followed still on the strap.
    func testAWristOffFromHistoryLeavesTheWearStateOn() {
        offload(Self.off[0], at: 900)
        offload(Self.on[10], at: 900)
        offload(Self.off[600], at: 900)
        XCTAssertTrue(live.worn)
        XCTAssertEqual(callbacks, [])
        XCTAssertEqual(lines(containing: "reached through a sync").count, 0)
    }

    /// A WRIST_OFF from history still orders what follows: a replay of an older WRIST_ON after it changes nothing.
    func testAWristOffFromHistoryStillMovesTheOrder() {
        router.handle(frame: bytes(Self.off[0]))
        offload(Self.off[600], at: 900)
        offload(Self.on[10], at: 900)
        XCTAssertFalse(live.worn)
    }

    /// W06-154: history may take back what history set. Taken off on the link, then put on and taken off again
    /// while unlinked: the offload carries both, and the strap is on the desk.
    func testAWristOffFromHistoryTakesBackAWristOnHistorySet() {
        router.handle(frame: bytes(Self.off[0]))
        offload(Self.on[10], at: 1_200)
        offload(Self.off[600], at: 1_200)
        XCTAssertFalse(live.worn, live.log.joined(separator: "\n"))
        XCTAssertEqual(callbacks, [false], "history must not run the wrist Shortcuts")
        XCTAssertEqual(lines(containing: "Wrist: WRIST_OFF reached through a sync").count, 1)
        offload(Self.on[900], at: 1_200)
        XCTAssertTrue(live.worn)
    }

    /// W06-154: a live event ends history's claim, so a WRIST_OFF from history after it leaves the wear state on.
    func testALiveEventEndsWhatHistorySet() {
        router.handle(frame: bytes(Self.off[0]))
        offload(Self.on[10], at: 1_200)
        router.handle(frame: bytes(Self.on[600]))
        offload(Self.off[900], at: 1_200)
        XCTAssertTrue(live.worn)
    }

    /// A live event is the strap's state now, even when the strap's clock stepped back behind an event history set.
    func testALiveEventAppliesEvenBehindANewerHistoricalOne() {
        offload(Self.on[600], at: 900)
        router.handle(frame: bytes(Self.off[0]))
        XCTAssertFalse(live.worn)
        XCTAssertEqual(callbacks, [false])
        // The live event is the new baseline, so an offload event after it on the stepped clock still counts.
        offload(Self.on[10], at: 20)
        XCTAssertTrue(live.worn)
    }

    /// W06-151, W06-158: the order is per physical strap, so a replacement strap on the same registry row, whose
    /// clock is behind the last one's, still has an offloaded event inside the live window heard.
    func testAnotherStrapOnTheSameRegistryRowStartsTheOrderAgain() {
        router.deviceId = "my-whoop"
        router.strapPeripheralId = "peripheral-a"
        router.handle(frame: bytes(Self.off[600]))
        router.family = .whoop5
        router.deviceId = "my-whoop"
        router.strapPeripheralId = "peripheral-b"
        offload(Self.on[10], at: 20)
        XCTAssertEqual(live.wristEventThisLink, true, live.log.joined(separator: "\n"))
        XCTAssertTrue(live.worn)
    }

    /// W06-159: the last strap's WRIST_OFF says nothing about the next one, so another strap starts from the default
    /// wear state. The wrist Shortcuts do not run: nothing happened on a wrist.
    func testAnotherStrapStartsFromTheDefaultWearState() {
        router.strapPeripheralId = "peripheral-a"
        router.handle(frame: bytes(Self.off[0]))
        router.strapPeripheralId = "peripheral-b"
        XCTAssertTrue(live.worn)
        XCTAssertEqual(callbacks, [false])
        XCTAssertEqual(lines(containing: "Wrist: another strap connected").count, 1)
    }

    /// The same strap re-announced at a connect keeps its order and its wear state.
    func testTheSameStrapReannouncedKeepsTheOrder() {
        router.strapPeripheralId = "peripheral-a"
        router.handle(frame: bytes(Self.off[600]))
        router.family = .whoop5
        router.strapPeripheralId = "peripheral-a"
        offload(Self.on[10], at: 900)
        XCTAssertFalse(live.worn)
    }

    /// A strap known only after the first connect of the process has nothing to reset.
    func testTheFirstStrapOfTheProcessResetsNothing() {
        router.handle(frame: bytes(Self.off[600]))
        router.strapPeripheralId = "peripheral-a"
        XCTAssertFalse(live.worn)
        offload(Self.on[10], at: 900)
        XCTAssertFalse(live.worn)
    }

    /// An event stamped ahead of the strap's own clock-now is not the strap's latest state; it must not block
    /// every later one either.
    func testAHistoricalEventFromTheFutureIsIgnored() {
        router.handle(frame: bytes(Self.off[0]))
        offload(Self.on[600], at: 0)
        XCTAssertFalse(live.worn)
        offload(Self.on[10], at: 900)
        XCTAssertTrue(live.worn)
    }
}
