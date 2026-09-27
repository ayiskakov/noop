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
        /// Fail `failing` once, then succeed.
        var failsOnce = false
        init(journal: Journal, failing: Step?) { self.journal = journal; self.failing = failing }

        private func refuse(_ step: Step) throws {
            guard failing == step else { return }
            if failsOnce { failing = nil }
            throw Refused()
        }

        @discardableResult
        func insert(_ streams: Streams, deviceId: String) async throws
            -> (hr: Int, rr: Int, events: Int, battery: Int,
                spo2: Int, skinTemp: Int, resp: Int, gravity: Int, v18Aux: Int) {
            journal.steps.append("insert")
            try refuse(.insert)
            return (0, 0, 0, 0, 0, 0, 0, 0, 0)
        }
        func enqueueRawBatch(_ meta: RawBatchMeta, frames: [[UInt8]]) async throws {
            journal.steps.append("raw")
            try refuse(.raw)
        }
        func setCursor(_ name: String, _ value: Int) async throws {
            journal.steps.append("cursor \(name)=\(value)")
            try refuse(.cursor)
        }
        func cursor(_ name: String) async throws -> Int? { nil }
    }

    /// An intact historical R21 record: no storage lane takes it, so it goes to the reject archive (W06-003).
    private let record = CollectorImuBankingTests.fixture

    private func historyEnd(trim: UInt32) -> [UInt8] {
        func le32(_ v: UInt32) -> [UInt8] { (0..<4).map { UInt8(truncatingIfNeeded: v >> (8 * UInt32($0))) } }
        return w5Frame(le32(1_700_000_000) + [0, 0] + le32(0) + le32(trim), type: 49, cmd: 2)
    }

    private func makeBackfiller(failing: SpyBackfillStore.Step? = nil, archiveFails: Bool = false,
                                rawCapture: Bool = true) -> (Backfiller, SpyBackfillStore, Journal) {
        let journal = Journal()
        let store = SpyBackfillStore(journal: journal, failing: failing)
        let backfiller = Backfiller(
            store: store, deviceId: "hold-ack",
            ackTrim: { trim, _ in journal.steps.append("ack \(trim)") },
            enableRawCapture: rawCapture,
            rejectedSink: { _, _, _, _ in journal.steps.append("archive"); return !archiveFails })
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

    /// The production default, raw capture off: the same order without the raw batch (W06-063).
    func testWithRawCaptureOffAChunkIsAckedAfterItsRowsArchiveAndCursor() async {
        let (backfiller, _, journal) = makeBackfiller(rawCapture: false)
        await offloadChunkThenEmptyEnd(backfiller)
        XCTAssertEqual(journal.steps, ["insert", "archive", "cursor strap_trim=100", "ack 100",
                                       "cursor strap_trim=101", "ack 101"])
        XCTAssertFalse(backfiller.persistStalled)
    }

    /// A chunk with records that stores fine after a stall still holds its ack: acking it would let the strap
    /// trim past the chunk that failed (W06-063).
    func testAChunkStoredDuringAStallIsNotAcked() async {
        for rawCapture in [false, true] {
            let (backfiller, store, journal) = makeBackfiller(failing: .insert, rawCapture: rawCapture)
            store.failsOnce = true
            await backfiller.ingest(record)
            await backfiller.ingest(historyEnd(trim: 100))
            await backfiller.ingest(record)   // the next chunk, stored fine
            await backfiller.ingest(historyEnd(trim: 101))
            XCTAssertEqual(journal.steps, ["insert", "insert", "archive"] + (rawCapture ? ["raw"] : []),
                           "raw capture \(rawCapture)")
            XCTAssertTrue(backfiller.persistStalled)
        }
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

/// W06-124, W06-135, W06-136: an END whose store write outlives its session (the link ends, or a new session
/// begins) stops at its resume. Its rows stay stored, but it archives nothing, moves neither the cursor nor
/// `lastAckedTrim`, acks nothing, and leaves the next session's tallies and stall flag alone. The idle timeout
/// alone is not such a boundary: an END still writing on the same link, with no session after it, acks.
@MainActor
final class StaleSessionChunkTests: XCTestCase {

    /// A store whose insert suspends until the test lets it go, then succeeds or throws.
    final class HeldStore: BackfillStoreWriting {
        struct Refused: Error {}
        var held: CheckedContinuation<Void, Never>?
        var insertThrows = false
        var steps: [String] = []

        @discardableResult
        func insert(_ streams: Streams, deviceId: String) async throws
            -> (hr: Int, rr: Int, events: Int, battery: Int,
                spo2: Int, skinTemp: Int, resp: Int, gravity: Int, v18Aux: Int) {
            steps.append("insert")
            await withCheckedContinuation { held = $0 }
            if insertThrows { throw Refused() }
            return (3, 0, 0, 0, 0, 0, 0, 0, 0)
        }
        func enqueueRawBatch(_ meta: RawBatchMeta, frames: [[UInt8]]) async throws { steps.append("raw") }
        func setCursor(_ name: String, _ value: Int) async throws { steps.append("cursor \(value)") }
        func cursor(_ name: String) async throws -> Int? { nil }
    }

    private let record = CollectorImuBankingTests.fixture

    private func historyEnd(trim: UInt32) -> [UInt8] {
        func le32(_ v: UInt32) -> [UInt8] { (0..<4).map { UInt8(truncatingIfNeeded: v >> (8 * UInt32($0))) } }
        return w5Frame(le32(1_700_000_000) + [0, 0] + le32(0) + le32(trim), type: 49, cmd: 2)
    }

    private enum Interruption { case none, linkEnds, timeout, newSession }

    /// One chunk (an archived record) whose END suspends in its insert while `interruption` happens.
    private func run(_ interruption: Interruption, insertThrows: Bool = false)
        async -> (Backfiller, HeldStore, steps: [String], lines: [String]) {
        let store = HeldStore()
        store.insertThrows = insertThrows
        var lines: [String] = []
        let backfiller = Backfiller(
            store: store, deviceId: "stale-session",
            ackTrim: { trim, _ in store.steps.append("ack \(trim)") },
            log: { lines.append($0) },
            rejectedSink: { _, _, _, _ in store.steps.append("archive"); return true })
        backfiller.begin(family: .whoop5)
        await backfiller.ingest(record)
        let end = Task { await backfiller.ingest(historyEnd(trim: 100)) }
        for _ in 0..<2_000 where store.held == nil { try? await Task.sleep(nanoseconds: 1_000_000) }
        XCTAssertNotNil(store.held, "the END reached its insert")
        switch interruption {
        case .none: break
        case .linkEnds: backfiller.linkEnded()
        case .timeout: backfiller.timeoutFired()
        case .newSession: backfiller.begin(family: .whoop5)
        }
        store.held?.resume()
        await end.value
        return (backfiller, store, store.steps, lines)
    }

    func testAnEndOnItsOwnSessionArchivesWritesTheCursorAndAcks() async {
        let (backfiller, _, steps, lines) = await run(.none)
        XCTAssertEqual(steps, ["insert", "archive", "cursor 100", "ack 100"])
        XCTAssertEqual(backfiller.lastAckedTrim, 100)
        XCTAssertEqual(backfiller.sessionRowsPersisted, 3)
        XCTAssertFalse(lines.contains { $0.contains("offload session ended while") })
    }

    func testAnEndThatOutlivedItsLinkArchivesNothingAndAcksNothing() async {
        for interruption in [Interruption.linkEnds, .newSession] {
            let (backfiller, _, steps, lines) = await run(interruption)
            XCTAssertEqual(steps, ["insert"], "\(interruption): its rows are stored and nothing else happens")
            XCTAssertNil(backfiller.lastAckedTrim, "\(interruption): W06-135")
            XCTAssertEqual(backfiller.sessionRowsPersisted, 0, "\(interruption): W06-124")
            XCTAssertEqual(lines.filter { $0.contains("offload session ended while chunk trim=100 was in progress; "
                                                      + "its rows are stored") }.count, 1,
                           "\(interruption): \(lines.joined(separator: "\n"))")
        }
    }

    /// A store write slower than the idle watchdog (queued behind a long re-score, W07-004) still acks: the END is
    /// on its own link and no session followed. Judging it stale would re-send the chunk into the same slow write
    /// every session, and the offload would never advance.
    func testAnEndWhoseWriteOutlastsTheIdleTimeoutStillAcks() async {
        let (backfiller, _, steps, lines) = await run(.timeout)
        XCTAssertEqual(steps, ["insert", "archive", "cursor 100", "ack 100"])
        XCTAssertEqual(backfiller.lastAckedTrim, 100)
        XCTAssertFalse(lines.contains { $0.contains("offload session ended while") })
    }

    /// W06-124: a failed write of the previous session's END must not stall the new session's acks.
    func testAFailedWriteOfAnEndFromAnEndedSessionDoesNotStallTheNextOne() async {
        let (backfiller, _, steps, lines) = await run(.newSession, insertThrows: true)
        XCTAssertEqual(steps, ["insert"])
        XCTAssertFalse(backfiller.persistStalled)
        XCTAssertFalse(lines.contains { $0.contains("failed to persist") }, lines.joined(separator: "\n"))
    }

    func testAFailedWriteInItsOwnSessionStillStalls() async {
        let (backfiller, _, _, _) = await run(.none, insertThrows: true)
        XCTAssertTrue(backfiller.persistStalled, "the #57 hold is unchanged for the session's own chunk")
    }
}
