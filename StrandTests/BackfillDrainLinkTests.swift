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
        XCTAssertEqual(lines.filter { $0.contains("the link ended during an ingest") }.count, 1, "\(lines)")
        XCTAssertTrue(lines.first?.contains("1 frame(s) of that link are not ingested") == true, "\(lines)")
    }
}
