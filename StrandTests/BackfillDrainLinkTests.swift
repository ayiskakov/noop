import XCTest
@testable import Strand

/// W06-008: the offload drain is single-flight within a link, but the link teardown cleared its draining flag
/// while a drain could still be suspended in an ingest (a chunk's END awaiting its store write). The next link's
/// first frame then started a second drain beside it: the new link's frames were ingested while the old END was
/// still suspended, and when it resumed, the old drain went on with the rest of its batch, which belonged to a
/// link that no longer existed.
@MainActor
final class BackfillDrainLinkTests: XCTestCase {
    private func frame(_ name: String) -> [UInt8] { Array(name.utf8) }
    private func name(_ frame: [UInt8]) -> String { String(decoding: frame, as: UTF8.self) }

    /// Yields until `condition` holds, failing after about two seconds.
    private func until(_ condition: () -> Bool, file: StaticString = #filePath, line: UInt = #line) async {
        for _ in 0..<2_000 where !condition() { try? await Task.sleep(nanoseconds: 1_000_000) }
        XCTAssertTrue(condition(), "timed out", file: file, line: line)
    }

    func testADrainSuspendedAcrossAReconnectNeitherInterleavesNorOutlivesItsLink() async {
        var events: [String] = []
        var held: CheckedContinuation<Void, Never>?
        var sessionActive = true
        var lines: [String] = []
        weak var drainRef: BackfillDrain?
        let drain = BackfillDrain(
            batchSize: 12,
            ingest: { [unowned self] f in
                let n = self.name(f)
                events.append("begin \(n)")
                if n == "A-END" { await withCheckedContinuation { held = $0 } }
                // What an END's ack would see: the old link's END must not ack on the new link, the new one must.
                if n.hasSuffix("-END") { events.append("ack stale=\(drainRef?.ingestOutlivedItsLink == true)") }
                events.append("end \(n)")
            },
            afterIngest: { sessionActive },
            log: { lines.append($0) })
        drainRef = drain

        // Link A: a chunk and one more frame in the same slice; its END suspends in the store write.
        for n in ["A-START", "A-1", "A-END", "A-2"] { drain.route(frame(n)) }
        await until { held != nil }

        // The link drops meanwhile, and the next link begins an offload of its own.
        sessionActive = false
        drain.linkEnded()
        sessionActive = true
        for n in ["B-START", "B-1", "B-END"] { drain.route(frame(n)) }
        try? await Task.sleep(nanoseconds: 50_000_000)

        held?.resume()
        await until { events.contains("end B-END") }

        XCTAssertEqual(events, [
            "begin A-START", "end A-START", "begin A-1", "end A-1", "begin A-END", "ack stale=true", "end A-END",
            "begin B-START", "end B-START", "begin B-1", "end B-1", "begin B-END", "ack stale=false", "end B-END",
        ], "the next link's frames wait for the old END, and the old link's remaining frame is not ingested")
        // W06-123: the wait is said, once, when the next link's drain starts behind the old one.
        XCTAssertEqual(lines.filter { $0.contains("waits for the previous link's drain") }.count, 1, "\(lines)")
        XCTAssertEqual(lines.filter { $0.contains("the link ended during an ingest") }.count, 1, "\(lines)")
        XCTAssertTrue(lines.contains { $0.contains("1 frame(s) of that link are not ingested") }, "\(lines)")
    }

    /// W06-137: on the same link, a session that ends during an ingest (the idle timeout) and restarts before it
    /// returns gets none of the rest of the slice the drain had already taken; the next session's frames follow.
    func testASessionThatEndsDuringAnIngestFeedsNoneOfItsSliceToTheNext() async {
        var ingested: [String] = []
        var held: CheckedContinuation<Void, Never>?
        var lines: [String] = []
        let drain = BackfillDrain(
            batchSize: 12,
            ingest: { [unowned self] f in
                let n = self.name(f)
                ingested.append(n)
                if n == "S1-END" { await withCheckedContinuation { held = $0 } }
            },
            afterIngest: { true },   // the next session has begun by the time the END returns
            log: { lines.append($0) })
        for n in ["S1-1", "S1-END", "S1-2", "S1-3"] { drain.route(frame(n)) }
        await until { held != nil }

        drain.dropQueued()           // exitBackfilling("timeout")
        drain.route(frame("S2-START"))
        held?.resume()
        await until { ingested.contains("S2-START") }

        XCTAssertEqual(ingested, ["S1-1", "S1-END", "S2-START"])
        XCTAssertEqual(lines.filter { $0.contains("2 frame(s) of it are not ingested into the next session") }.count, 1,
                       "\(lines)")
    }

    /// W06-123: a drain that starts with no earlier one still running says nothing.
    func testAnOrdinaryDrainLogsNoWait() async {
        var lines: [String] = []
        var ingested = 0
        let drain = BackfillDrain(batchSize: 12, ingest: { _ in ingested += 1 }, afterIngest: { true },
                                  log: { lines.append($0) })
        drain.route([1]); drain.route([2])
        await until { ingested == 2 }
        drain.linkEnded()
        drain.route([3])
        await until { ingested == 3 }
        XCTAssertEqual(lines, [])
    }
}

/// W06-125: the ack a chunk's END asks for is not sent when that END began ingesting on a link that has since
/// ended (W06-008's decision), and is sent otherwise.
@MainActor
final class StaleChunkAckTests: XCTestCase {
    private var live: LiveState!
    private var manager: BLEManager!

    override func setUp() async throws {
        live = LiveState()
        manager = BLEManager(state: live, deviceId: "rig-\(UUID().uuidString)", collector: nil)
    }

    override func tearDown() async throws {
        manager = nil
        live = nil
    }

    /// Runs one END through a drain whose ingest suspends before it acks, optionally ending the link meanwhile.
    private func ackAcross(linkEnds: Bool, atBoundary: Bool = false) async {
        var held: CheckedContinuation<Void, Never>?
        var acked = false
        let endData: [UInt8] = [7, 0, 0, 0, 8, 0, 0, 0]
        manager.backfillDrain = BackfillDrain(
            batchSize: 12,
            ingest: { [unowned self] _ in
                await withCheckedContinuation { held = $0 }
                self.manager.ackHistoricalChunk(trim: 7, endData: endData)
                acked = true
            },
            afterIngest: { true })
        manager.backfillDrain.route([0x2f])
        for _ in 0..<2_000 where held == nil { try? await Task.sleep(nanoseconds: 1_000_000) }
        if linkEnds {
            if atBoundary { manager.offloadLinkBoundary() } else { manager.backfillDrain.linkEnded() }
        }
        held?.resume()
        for _ in 0..<2_000 where !acked { try? await Task.sleep(nanoseconds: 1_000_000) }
        XCTAssertTrue(acked)
    }

    func testAnEndThatOutlivedItsLinkIsNotAcked() async {
        await ackAcross(linkEnds: true)
        XCTAssertEqual(live.syncChunksThisSession, 0, "no ack may go out for a chunk of a link that ended")
        XCTAssertEqual(live.log.filter { $0.contains("chunk ack (trim=7) not sent") }.count, 1,
                       live.log.joined(separator: "\n"))
    }

    /// W06-138: the boundary `didConnect` marks as well as the teardown, so a link that begins without a
    /// teardown still leaves the previous link's END unacked. (`didConnect` itself needs a `CBPeripheral`, which
    /// a test cannot make, so its call is not pinned here.)
    func testTheLinkBoundaryMakesAnEndInFlightStale() async {
        await ackAcross(linkEnds: true, atBoundary: true)
        XCTAssertEqual(live.syncChunksThisSession, 0)
        XCTAssertEqual(live.log.filter { $0.contains("chunk ack (trim=7) not sent") }.count, 1,
                       live.log.joined(separator: "\n"))
    }

    func testAnEndOnTheCurrentLinkIsAcked() async {
        await ackAcross(linkEnds: false)
        XCTAssertEqual(live.syncChunksThisSession, 1)
        XCTAssertFalse(live.log.contains { $0.contains("not sent") })
    }
}
