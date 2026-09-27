import XCTest
@testable import Strand

/// W06-109: an empty offload from a strap that reported WRIST_OFF on this link is not a clock or charge
/// state. The 2026-09-27 export: the strap logged WRIST_OFF, and the next two periodic offloads, 10 min
/// apart, each printed "a clock/charge state on the strap … fully charge it"; a third would have raised the
/// no-flash-cursor banner.
final class EmptyOffloadWristTests: XCTestCase {

    // MARK: - The no-cursor line

    func testAnOffWristNoCursorLineStatesTheWristAndGivesNoChargeAdvice() {
        let line = Backfiller.noCursorLine(rowsPersisted: 0, strapOffWrist: true)
        XCTAssertTrue(line.contains("WRIST_OFF"), line)
        XCTAssertFalse(line.contains("clock/charge state"), line)
        XCTAssertFalse(line.contains("fully charge"), line)
        XCTAssertFalse(line.contains("\u{2014}"), line)
    }

    /// Rows persisted this run, or earlier in the burst, still read as caught up: the wrist changes nothing.
    func testRowsStillReadAsCaughtUpOffTheWrist() {
        XCTAssertEqual(Backfiller.noCursorLine(rowsPersisted: 5, strapOffWrist: true),
                       Backfiller.noCursorLine(rowsPersisted: 5))
        XCTAssertEqual(Backfiller.noCursorLine(rowsPersisted: 0, continuedAfterRows: true, strapOffWrist: true),
                       Backfiller.noCursorLine(rowsPersisted: 0, continuedAfterRows: true))
    }

    // MARK: - The empty-sync streak

    /// Three off-wrist empty cycles, the export's shape run one cycle further, raise nothing.
    func testOffWristEmptyCyclesNeverRaiseTheBanner() {
        var t = EmptySyncTracker()
        for _ in 0..<3 {
            XCTAssertFalse(t.recordCompletedSync(bankedSensorRecords: false, consoleOnly: true, strapOffWrist: true))
        }
        XCTAssertEqual(t.consecutiveEmptySyncs, 0)
    }

    /// An off-wrist cycle neither counts nor clears: a strap already two empty cycles in, taken off and
    /// put back on, warns on its next empty cycle on the wrist.
    func testAnOffWristCycleNeitherCountsNorClears() {
        var t = EmptySyncTracker()
        XCTAssertFalse(t.recordCompletedSync(bankedSensorRecords: false, consoleOnly: true))
        XCTAssertFalse(t.recordCompletedSync(bankedSensorRecords: false, consoleOnly: true))
        XCTAssertFalse(t.recordCompletedSync(bankedSensorRecords: false, consoleOnly: true, strapOffWrist: true))
        XCTAssertEqual(t.consecutiveEmptySyncs, 2)
        XCTAssertTrue(t.recordCompletedSync(bankedSensorRecords: false, consoleOnly: true))
    }

    /// W06-116: a banner the on-wrist cycles raised stays up through an off-wrist cycle: the excused cycle
    /// reports the sustained streak it leaves standing, and the call site keeps the banner branch for it.
    func testAnOffWristCycleKeepsABannerAlreadyRaised() {
        var t = EmptySyncTracker()
        _ = t.recordCompletedSync(bankedSensorRecords: false, consoleOnly: true)
        _ = t.recordCompletedSync(bankedSensorRecords: false, consoleOnly: true)
        XCTAssertTrue(t.recordCompletedSync(bankedSensorRecords: false, consoleOnly: true))
        XCTAssertTrue(t.recordCompletedSync(bankedSensorRecords: false, consoleOnly: true, strapOffWrist: true))
        XCTAssertEqual(t.consecutiveEmptySyncs, 3)
    }

    // MARK: - The per-link wrist record

    /// Real WHOOP 5 EVENT frames: the captured DOUBLE_TAP(14) frame of `FrameRouterDoubleTapDedupTests`
    /// with its event byte set to WRIST_OFF(10) or WRIST_ON(9) and the payload CRC32 (bytes 8..<20)
    /// recomputed. `event_timestamp` = 1780910464.
    private let wristOffHex = "aa0110000100208130340a008089266a3d2a00004a18349b"
    private let wristOnHex = "aa01100001002081303409008089266a3d2a000049a30370"

    private func bytes(_ hex: String) -> [UInt8] {
        stride(from: 0, to: hex.count, by: 2).compactMap {
            let i = hex.index(hex.startIndex, offsetBy: $0)
            return UInt8(hex[i..<hex.index(i, offsetBy: 2)], radix: 16)
        }
    }

    @MainActor
    func testALiveWristOffIsRecordedForTheLinkAndLoggedOnce() {
        let live = LiveState()
        let router = FrameRouter(state: live)
        router.family = .whoop5
        XCTAssertNil(live.wristEventThisLink)

        router.handle(frame: bytes(wristOffHex))
        router.dispatchLiveGestureIfFresh(frame: bytes(wristOffHex), now: 1_780_910_464 + 5)

        XCTAssertEqual(live.wristEventThisLink, false)
        XCTAssertFalse(live.worn)
        XCTAssertEqual(live.log.filter { $0.contains("Wrist: WRIST_OFF on this link") }.count, 1,
                       live.log.joined(separator: "\n"))

        router.handle(frame: bytes(wristOnHex))
        XCTAssertEqual(live.wristEventThisLink, true)
        XCTAssertTrue(live.worn)
        XCTAssertEqual(live.log.filter { $0.contains("Wrist: WRIST_ON on this link") }.count, 1)
    }
}
