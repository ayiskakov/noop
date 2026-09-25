import XCTest
import WhoopProtocol
import WhoopStore
@testable import Strand

/// W06-007: the safe-trim invariant's hold-ack paths. A chunk's HISTORY_END is acked only after its decoded
/// rows, its archived rejects, its raw frames (raw capture on) and the `strap_trim` cursor are written, in
/// that order. A failure at any step holds that ack and every later one in the session, empty ENDs included,
/// so the strap cannot trim past a chunk that was never stored. Until these, deleting any of those `return`s
/// in `finishChunk` passed every test.
@MainActor
final class BackfillerHoldAckTests: XCTestCase {

    /// One ordered record of every write the Backfiller makes and every ack it sends.
    final class Journal { var steps: [String] = [] }

    /// The `SpyBackfillStore` the Backfiller's doc names: journals each write, and fails the one step a test
    /// names after journalling it.
    final class SpyBackfillStore: BackfillStoreWriting {
        enum Step { case insert, raw, cursor }
        struct Refused: Error {}
        let journal: Journal
        var failing: Step?
        init(journal: Journal, failing: Step?) { self.journal = journal; self.failing = failing }

        @discardableResult
        func insert(_ streams: Streams, deviceId: String) async throws
            -> (hr: Int, rr: Int, events: Int, battery: Int,
                spo2: Int, skinTemp: Int, resp: Int, gravity: Int, v18Aux: Int) {
            journal.steps.append("insert")
            if failing == .insert { throw Refused() }
            return (0, 0, 0, 0, 0, 0, 0, 0, 0)
        }
        func enqueueRawBatch(_ meta: RawBatchMeta, frames: [[UInt8]]) async throws {
            journal.steps.append("raw")
            if failing == .raw { throw Refused() }
        }
        func setCursor(_ name: String, _ value: Int) async throws {
            journal.steps.append("cursor \(name)=\(value)")
            if failing == .cursor { throw Refused() }
        }
        func cursor(_ name: String) async throws -> Int? { nil }
    }

    /// An intact historical R21 record: no storage lane takes it, so it goes to the reject archive (W06-003).
    private let record = CollectorImuBankingTests.fixture

    private func historyEnd(trim: UInt32) -> [UInt8] {
        func le32(_ v: UInt32) -> [UInt8] { (0..<4).map { UInt8(truncatingIfNeeded: v >> (8 * UInt32($0))) } }
        return w5Frame(le32(1_700_000_000) + [0, 0] + le32(0) + le32(trim), type: 49, cmd: 2)
    }

    private func makeBackfiller(failing: SpyBackfillStore.Step? = nil, archiveFails: Bool = false)
        -> (Backfiller, SpyBackfillStore, Journal) {
        let journal = Journal()
        let store = SpyBackfillStore(journal: journal, failing: failing)
        let backfiller = Backfiller(
            store: store, deviceId: "hold-ack",
            ackTrim: { trim, _ in journal.steps.append("ack \(trim)") },
            enableRawCapture: true,
            rejectedSink: { _, _, _ in journal.steps.append("archive"); return !archiveFails })
        backfiller.begin(family: .whoop5)
        return (backfiller, store, journal)
    }

    /// One records-bearing chunk ending at `trim` 100, then an empty END at 101.
    private func offloadChunkThenEmptyEnd(_ backfiller: Backfiller) async {
        await backfiller.ingest(record)
        await backfiller.ingest(historyEnd(trim: 100))
        await backfiller.ingest(historyEnd(trim: 101))
    }

    func testTheRecordIsArchivedNotStored() {
        XCTAssertEqual(rejectedHistoricalRecords([record], family: .whoop5).count, 1,
                       "precondition: the chunk takes the archive path")
    }

    func testAStoredChunkIsAckedAfterEveryWriteInOrder() async {
        let (backfiller, _, journal) = makeBackfiller()
        await offloadChunkThenEmptyEnd(backfiller)
        XCTAssertEqual(journal.steps, ["insert", "archive", "raw", "cursor strap_trim=100", "ack 100",
                                       "cursor strap_trim=101", "ack 101"])
        XCTAssertFalse(backfiller.persistStalled)
    }

    func testAFailedInsertHoldsItsAckAndTheEmptyEndAfterIt() async {
        let (backfiller, _, journal) = makeBackfiller(failing: .insert)
        await offloadChunkThenEmptyEnd(backfiller)
        XCTAssertEqual(journal.steps, ["insert"])
        XCTAssertTrue(backfiller.persistStalled)
    }

    func testAFailedArchiveHoldsItsAckAndTheEmptyEndAfterIt() async {
        let (backfiller, _, journal) = makeBackfiller(archiveFails: true)
        await offloadChunkThenEmptyEnd(backfiller)
        XCTAssertEqual(journal.steps, ["insert", "archive"])
        XCTAssertTrue(backfiller.persistStalled)
    }

    func testAFailedRawBatchHoldsItsAckAndTheEmptyEndAfterIt() async {
        let (backfiller, _, journal) = makeBackfiller(failing: .raw)
        await offloadChunkThenEmptyEnd(backfiller)
        XCTAssertEqual(journal.steps, ["insert", "archive", "raw"])
        XCTAssertTrue(backfiller.persistStalled)
    }

    func testAFailedCursorWriteHoldsItsAckAndTheEmptyEndAfterIt() async {
        let (backfiller, _, journal) = makeBackfiller(failing: .cursor)
        await offloadChunkThenEmptyEnd(backfiller)
        XCTAssertEqual(journal.steps, ["insert", "archive", "raw", "cursor strap_trim=100"])
        XCTAssertTrue(backfiller.persistStalled)
    }

    /// The stall lasts for the session only: the next offload, with a working store, acks again.
    func testANewSessionClearsTheStall() async {
        let (backfiller, store, journal) = makeBackfiller(failing: .insert)
        await offloadChunkThenEmptyEnd(backfiller)
        store.failing = nil
        backfiller.begin(family: .whoop5)
        await backfiller.ingest(historyEnd(trim: 102))
        XCTAssertEqual(journal.steps, ["insert", "cursor strap_trim=102", "ack 102"])
        XCTAssertFalse(backfiller.persistStalled)
    }
}
