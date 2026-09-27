import XCTest
import WhoopProtocol
import WhoopStore
@testable import Strand

/// W06-005: v20 and v21 are mapped layouts with no storage lane, so every one of their records is archived raw.
/// Every sync then reported them as records that "couldn't be decoded", the per-chunk line blamed a CRC or an
/// unmapped layout, and Sleep's freshness note read the sync as failed. W06-129: an intact v16 record whose FIFO
/// holds no sample is the same case, and W06-131 … W06-133: the lines and the status name only what they saw.
@MainActor
final class RecordsWithoutLaneSyncStatusTests: XCTestCase {
    /// A real v21 (IMU) record.
    private let v21 = CollectorImuBankingTests.fixture
    /// A real v16 record whose FIFO holds no sample (the `emptyHex` fixture in `Whoop5HistoricalV16Tests`).
    private let emptyV16: [UInt8] = {
        let hex: String =
        "aa0128060100cde02f100372c3c7018115b16a3d2a0003000100000000ffff0000000000000000000000000000000000"
        + "000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000"
        + "000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000"
        + "000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000"
        + "000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000"
        + "000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000"
        + "000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000"
        + "000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000"
        + "000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000"
        + "000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000"
        + "000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000"
        + "000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000"
        + "000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000"
        + "000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000"
        + "000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000"
        + "000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000"
        + "000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000"
        + "000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000"
        + "000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000"
        + "000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000"
        + "000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000"
        + "000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000"
        + "000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000"
        + "000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000"
        + "000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000"
        + "000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000"
        + "000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000"
        + "000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000"
        + "000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000"
        + "000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000"
        + "000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000"
        + "000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000"
        + "000000000000000000000000000000000000000000000000000000000000000000000000000000000000000088a5f065"
        var out: [UInt8] = []
        var i = hex.startIndex
        while i < hex.endIndex {
            let j = hex.index(i, offsetBy: 2)
            out.append(UInt8(hex[i..<j], radix: 16)!)
            i = j
        }
        return out
    }()

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

    private func runChunk(_ records: [[UInt8]]) async -> (lines: [String], archived: [[UInt8]], intact: Int) {
        var lines: [String] = []
        var archived: [[UInt8]] = []
        var intact = 0
        let backfiller = Backfiller(store: NoopStore(), deviceId: "w06-005", ackTrim: { _, _ in },
                                    log: { lines.append($0) },
                                    rejectedSink: { frames, _, _, n in archived += frames; intact += n; return true })
        backfiller.begin(family: .whoop5)
        for r in records { await backfiller.ingest(r) }
        await backfiller.ingest(historyEnd(trim: 100))
        return (lines, archived, intact)
    }

    func testTheFixturesAreIntactRecordsThatBankNoRow() {
        XCTAssertEqual(classifyRejectedHistoricalRecords([v21, emptyV16], family: .whoop5).map(\.rejection),
                       [.noStorageLane, .noSamples])
    }

    func testAChunkOfV21SaysSoAndDumpsNoHex() async {
        let (lines, archived, intact) = await runChunk([v21])
        let all = lines.joined(separator: "\n")
        XCTAssertEqual(archived, [v21], "the record is still archived raw before the ack")
        XCTAssertEqual(intact, 1, "the sink is told how many of them are intact, so the status can leave them out")
        XCTAssertEqual(lines.filter { $0.contains("1 intact record(s) (v21: 1)") && $0.contains("no storage lane") }.count, 1,
                       "W06-133: the versions come from the chunk's frames, not the lane set: \(all)")
        XCTAssertFalse(lines.contains { $0.contains("undecodable") }, all)
        XCTAssertFalse(lines.contains { $0.contains("rejected frame[") }, "the hex dump is for unmapped layouts")
        XCTAssertFalse(lines.contains { $0.contains("archiving") }, "W06-132: no line claims what the archive does")
    }

    /// W06-129: an intact v16 record with no FIFO sample is archived, and is not undecodable.
    func testAChunkOfAnEmptyV16IsNotUndecodable() async {
        let (lines, archived, intact) = await runChunk([emptyV16])
        let all = lines.joined(separator: "\n")
        XCTAssertEqual(archived, [emptyV16])
        XCTAssertEqual(intact, 1)
        XCTAssertEqual(lines.filter { $0.contains("1 intact v16 record(s)") && $0.contains("no FIFO sample") }.count, 1, all)
        XCTAssertFalse(lines.contains { $0.contains("undecodable") }, all)
        XCTAssertFalse(lines.contains { $0.contains("rejected frame[") }, all)
    }

    /// A corrupted record is undecodable: counted as such, dumped, and its cause named from the screen's reason.
    func testACorruptedRecordIsUndecodableAndItsCauseNamed() async {
        var bad = v21
        bad[bad.count - 1] ^= 0xff
        let (lines, archived, intact) = await runChunk([bad, v21])
        let all = lines.joined(separator: "\n")
        XCTAssertEqual(archived, [bad, v21])
        XCTAssertEqual(intact, 1)
        XCTAssertEqual(lines.filter { $0.contains("1 undecodable sensor record(s)") && $0.contains("(1 failed the integrity check)") }.count,
                       1, all)
        XCTAssertEqual(lines.filter { $0.contains("rejected frame[0]") }.count, 1, all)
    }

    func testRecordsThatBankNoRowRaiseNoSyncError() {
        XCTAssertNil(BLEManager.undecodableRecordsSyncError(archived: 240, unarchived: 0,
                                                            intact: 240, intactUnarchived: 0))
        XCTAssertNil(BLEManager.undecodableRecordsSyncError(archived: 0, unarchived: 240,
                                                            intact: 0, intactUnarchived: 240),
                     "a full archive dropping them is W06-003's retention question, said in the log")
    }

    func testUndecodableRecordsBesideThemAreCountedAlone() {
        let saved = BLEManager.undecodableRecordsSyncError(archived: 243, unarchived: 0,
                                                           intact: 240, intactUnarchived: 0)
        XCTAssertTrue(saved?.hasPrefix("Synced, but 3 record(s) couldn't be decoded") == true, saved ?? "nil")
        XCTAssertTrue(saved?.contains("saved on this device") == true, "not \"this Mac\": the same text shows on iOS")
        let lost = BLEManager.undecodableRecordsSyncError(archived: 242, unarchived: 241,
                                                          intact: 240, intactUnarchived: 240)
        XCTAssertTrue(lost?.hasPrefix("Synced, but 3 record(s) couldn't be decoded") == true, lost ?? "nil")
        XCTAssertTrue(lost?.contains("the 1 newest weren't preserved") == true, lost ?? "nil")
        for text in [saved, lost] {
            XCTAssertFalse(text?.contains("layout") ?? true, "W06-131: the remainder holds checksum failures too: \(text ?? "nil")")
        }
    }
}
