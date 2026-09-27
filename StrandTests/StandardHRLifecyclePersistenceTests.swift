import XCTest
import StrandAnalytics
import WhoopProtocol
import WhoopStore
@testable import Strand

@MainActor
final class StandardHRLifecyclePersistenceTests: XCTestCase {
    private final class CountingStore: StoreWriting {
        private(set) var offeredHRRows = 0
        private(set) var offeredRRRows = 0

        func insert(_ streams: Streams, deviceId: String) async throws
            -> (hr: Int, rr: Int, events: Int, battery: Int,
                spo2: Int, skinTemp: Int, resp: Int, gravity: Int, v18Aux: Int) {
            offeredHRRows = streams.hr.count
            offeredRRRows = streams.rr.count
            // Deliberately differ from the offered counts: this is the store's conflict/dedup result.
            return (0, 1, 0, 0, 0, 0, 0, 0, 0)
        }

        func enqueueRawBatch(_ meta: RawBatchMeta, frames: [[UInt8]]) async throws {}
    }

    func testBackgroundLifecycleFlushesSubThresholdStandardHRAndLogsStoreCounts() async {
        let store = CountingStore()
        var lines: [String] = []
        let collector = Collector(
            store: store,
            deviceId: "test-strap",
            log: { lines.append($0) },
            now: { 1_750_000_000 }
        )
        let manager = BLEManager(state: LiveState(), collector: collector)

        // Three accepted rows are intentionally below the 30-row cadence threshold. The invalid values
        // prove that the host-receipt line reports Collector's accepted/rejected split, not input totals.
        collector.ingestStandardHR(hr: 72, rr: [800, 100, 900], at: 1_750_000_000)
        XCTAssertEqual(store.offeredHRRows + store.offeredRRRows, 0)

        await manager.flushStandardHRForLifecycle(reason: .background)

        XCTAssertEqual(store.offeredHRRows, 1)
        XCTAssertEqual(store.offeredRRRows, 2)
        // W06-118: the batch rejected a value, so its receipt summary prints with Test Centre off.
        XCTAssertTrue(lines.contains(
            "standard-hr transport host-received-summary readings=1 hostUnixSec=1750000000...1750000000"
                + " maxGapSec=0 acceptedHRRows=1 acceptedRRRows=2 rejectedHRRows=0 rejectedRRRows=1"
        ), lines.joined(separator: "\n"))
        XCTAssertTrue(lines.contains(
            "standard-hr transport flush-succeeded reason=background"
                + " offeredHRRows=1 offeredRRRows=2 insertedHRRows=0 insertedRRRows=1"
        ))
    }

    // MARK: - W06-108 / W06-118: one receipt summary per flush, the per-reading line under Log Everything

    /// Runs `body` with Test Centre's connection and master flags set as given. Both keys live in the test
    /// host's defaults, so they are restored afterwards.
    private func withTestCentre(connection: Bool, master: Bool = false, _ body: () async -> Void) async {
        let keys = ["testcentre.active.connection", "testcentre.active.master"]
        let saved = keys.map { UserDefaults.standard.object(forKey: $0) }
        if connection { TestCentre.activate(.connection) } else { TestCentre.deactivate(.connection) }
        if master { TestCentre.activate(.master) } else { UserDefaults.standard.removeObject(forKey: keys[1]) }
        await body()
        for (key, value) in zip(keys, saved) {
            if let value { UserDefaults.standard.set(value, forKey: key) } else { UserDefaults.standard.removeObject(forKey: key) }
        }
    }

    /// Ingests `readings` (HR, R-R) one second apart, flushes, and returns the lines logged.
    private func lines(for readings: [(Int, [Int])]) async -> [String] {
        var lines: [String] = []
        let collector = Collector(store: CountingStore(), deviceId: "test-strap",
                                  log: { lines.append($0) }, now: { 1_750_000_000 })
        for (i, r) in readings.enumerated() {
            collector.ingestStandardHR(hr: r.0, rr: r.1, at: 1_750_000_000 + i)
        }
        await collector.flushStandardHR(reason: .explicit)
        return lines
    }

    private func count(_ lines: [String], _ needle: String) -> Int { lines.filter { $0.contains(needle) }.count }

    func testACleanBatchLogsNoReceiptLineOutsideTestCentre() async {
        await withTestCentre(connection: false) {
            let lines = await lines(for: [(72, [800]), (73, [810]), (74, [790])])
            XCTAssertEqual(count(lines, "host-received"), 0, lines.joined(separator: "\n"))
            // The flush lines, which say what landed, stay always-on.
            XCTAssertEqual(count(lines, "standard-hr transport flush-succeeded"), 1, lines.joined(separator: "\n"))
        }
    }

    /// The owner's configuration: Connection on. Three readings give ONE summary line, not three.
    func testTestCentreConnectionLogsOneSummaryPerFlush() async {
        await withTestCentre(connection: true) {
            let lines = await lines(for: [(72, [800]), (73, [810]), (74, [790])])
            XCTAssertEqual(lines.filter { $0.hasPrefix("standard-hr transport host-received") }, [
                "standard-hr transport host-received-summary readings=3 hostUnixSec=1750000000...1750000002"
                    + " maxGapSec=1 acceptedHRRows=3 acceptedRRRows=3 rejectedHRRows=0 rejectedRRRows=0"
            ], lines.joined(separator: "\n"))
        }
    }

    /// A strap rejecting every reading reports once per flush, not once per reading, with Test Centre off.
    func testRejectedReadingsLogOneSummaryOutsideTestCentre() async {
        await withTestCentre(connection: false) {
            let lines = await lines(for: [(0, []), (0, []), (0, []), (72, [100])])
            XCTAssertEqual(lines.filter { $0.hasPrefix("standard-hr transport host-received") }, [
                "standard-hr transport host-received-summary readings=4 hostUnixSec=1750000000...1750000003"
                    + " maxGapSec=1 acceptedHRRows=1 acceptedRRRows=0 rejectedHRRows=3 rejectedRRRows=1"
            ], lines.joined(separator: "\n"))
        }
    }

    /// Log Everything keeps the per-reading line.
    func testLogEverythingKeepsThePerReadingLine() async {
        await withTestCentre(connection: false, master: true) {
            let lines = await lines(for: [(72, [800]), (73, [810])])
            XCTAssertEqual(count(lines, "standard-hr transport host-received hostUnixSec="), 2, lines.joined(separator: "\n"))
        }
    }
}
