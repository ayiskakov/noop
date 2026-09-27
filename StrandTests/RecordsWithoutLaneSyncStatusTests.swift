import XCTest
import WhoopProtocol
import WhoopStore
@testable import Strand

/// W06-005: v20 and v21 are mapped layouts with no storage lane, so every one of their records is archived raw.
/// Every sync then reported them as records that "couldn't be decoded", the per-chunk line blamed a CRC or an
/// unmapped layout, and Sleep's freshness note read the sync as failed.
@MainActor
final class RecordsWithoutLaneSyncStatusTests: XCTestCase {
    /// A real v21 (IMU) record.
    private let v21 = CollectorImuBankingTests.fixture

    private final class NoopStore: BackfillStoreWriting {
        @discardableResult
        func insert(_ streams: Streams, deviceId: String) async throws
            -> (hr: Int, rr: Int, events: Int, battery: Int,
                spo2: Int, skinTemp: Int, resp: Int, gravity: Int, v18Aux: Int) {
            (0, 0, 0, 0, 0, 0, 0, 0, 0)
        }
        func enqueueRawBatch(_ meta: RawBatchMeta, frames: [[UInt8]]) async throws {}
        func setCursor(_ name: String, _ value: Int) async throws {}
        func cursor(_ name: String) async throws -> Int? { nil }
    }

    private func historyEnd(trim: UInt32) -> [UInt8] {
        func le32(_ v: UInt32) -> [UInt8] { (0..<4).map { UInt8(truncatingIfNeeded: v >> (8 * UInt32($0))) } }
        return w5Frame(le32(1_700_000_000) + [0, 0] + le32(0) + le32(trim), type: 49, cmd: 2)
    }

    func testTheFixtureIsAnIntactRecordWithoutALane() {
        XCTAssertTrue(isIntactRecordWithoutStorageLane(v21))
    }

    func testAChunkOfV21SaysSoAndDumpsNoHex() async {
        var lines: [String] = []
        var archived: [[UInt8]] = []
        var withoutLane = 0
        let backfiller = Backfiller(store: NoopStore(), deviceId: "w06-005", ackTrim: { _, _ in },
                                    log: { lines.append($0) },
                                    rejectedSink: { frames, _, _, n in archived += frames; withoutLane += n; return true })
        backfiller.begin(family: .whoop5)
        await backfiller.ingest(v21)
        await backfiller.ingest(historyEnd(trim: 100))

        XCTAssertEqual(archived, [v21], "the record is still archived raw before the ack")
        XCTAssertEqual(withoutLane, 1, "the sink is told how many of them have no lane, so the status can leave them out")
        XCTAssertEqual(lines.filter { $0.contains("1 intact v20/v21 record(s)") && $0.contains("no storage lane") }.count, 1,
                       lines.joined(separator: "\n"))
        XCTAssertFalse(lines.contains { $0.contains("undecodable") }, lines.joined(separator: "\n"))
        XCTAssertFalse(lines.contains { $0.contains("rejected frame[") }, "the hex dump is for unmapped layouts")
    }

    func testRecordsWithoutALaneRaiseNoSyncError() {
        XCTAssertNil(BLEManager.undecodableRecordsSyncError(archived: 240, unarchived: 0,
                                                            withoutLane: 240, withoutLaneUnarchived: 0))
        XCTAssertNil(BLEManager.undecodableRecordsSyncError(archived: 0, unarchived: 240,
                                                            withoutLane: 0, withoutLaneUnarchived: 240),
                     "a full archive dropping them is W06-003's retention question, said in the log")
    }

    func testUndecodableRecordsBesideThemAreCountedAlone() {
        let saved = BLEManager.undecodableRecordsSyncError(archived: 243, unarchived: 0,
                                                           withoutLane: 240, withoutLaneUnarchived: 0)
        XCTAssertTrue(saved?.hasPrefix("Synced, but 3 record(s) couldn't be decoded") == true, saved ?? "nil")
        XCTAssertTrue(saved?.contains("saved on this device") == true, "not \"this Mac\": the same text shows on iOS")
        let lost = BLEManager.undecodableRecordsSyncError(archived: 242, unarchived: 241,
                                                          withoutLane: 240, withoutLaneUnarchived: 240)
        XCTAssertTrue(lost?.hasPrefix("Synced, but 3 record(s) couldn't be decoded") == true, lost ?? "nil")
        XCTAssertTrue(lost?.contains("the 1 newest weren't preserved") == true, lost ?? "nil")
    }
}
