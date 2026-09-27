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
        XCTAssertTrue(lines.contains(
            "standard-hr transport host-received hostUnixSec=1750000000"
                + " acceptedHRRows=1 acceptedRRRows=2 rejectedHRRows=0 rejectedRRRows=1"
                + " pendingHRRows=1 pendingRRRows=2"
        ))
        XCTAssertTrue(lines.contains(
            "standard-hr transport flush-succeeded reason=background"
                + " offeredHRRows=1 offeredRRRows=2 insertedHRRows=0 insertedRRRows=1"
        ))
    }

    // MARK: - W06-108: the per-reading line is a Test Centre readout

    /// Runs `body` with Test Centre's connection domain set as given and the master flag, which implies every
    /// domain, off. Both keys live in the test host's defaults, so they are restored afterwards.
    private func withTestCentreConnection(_ on: Bool, _ body: () async -> Void) async {
        let keys = ["testcentre.active.connection", "testcentre.active.master"]
        let saved = keys.map { UserDefaults.standard.object(forKey: $0) }
        UserDefaults.standard.removeObject(forKey: keys[1])
        if on { TestCentre.activate(.connection) } else { TestCentre.deactivate(.connection) }
        await body()
        for (key, value) in zip(keys, saved) {
            if let value { UserDefaults.standard.set(value, forKey: key) } else { UserDefaults.standard.removeObject(forKey: key) }
        }
    }

    /// Ingests one reading with nothing out of range, flushes it, and returns the lines logged.
    private func linesForACleanReading() async -> [String] {
        var lines: [String] = []
        let collector = Collector(store: CountingStore(), deviceId: "test-strap",
                                  log: { lines.append($0) }, now: { 1_750_000_000 })
        collector.ingestStandardHR(hr: 72, rr: [800], at: 1_750_000_000)
        await collector.flushStandardHR(reason: .explicit)
        return lines
    }

    func testACleanReadingLogsNoHostLineOutsideTestCentre() async {
        await withTestCentreConnection(false) {
            let lines = await linesForACleanReading()
            XCTAssertFalse(lines.contains { $0.contains("host-received") }, lines.joined(separator: "\n"))
            // The flush lines, which say what landed, stay always-on.
            XCTAssertTrue(lines.contains { $0.hasPrefix("standard-hr transport flush-succeeded") },
                          lines.joined(separator: "\n"))
        }
    }

    func testTestCentreConnectionLogsEveryReading() async {
        await withTestCentreConnection(true) {
            let lines = await linesForACleanReading()
            XCTAssertTrue(lines.contains(
                "standard-hr transport host-received hostUnixSec=1750000000"
                    + " acceptedHRRows=1 acceptedRRRows=1 rejectedHRRows=0 rejectedRRRows=0"
                    + " pendingHRRows=1 pendingRRRows=1"
            ), lines.joined(separator: "\n"))
        }
    }

    /// A reading with a rejected value is rare evidence and logs with Test Centre off.
    func testARejectedValueLogsItsReadingOutsideTestCentre() async {
        await withTestCentreConnection(false) {
            var lines: [String] = []
            let collector = Collector(store: CountingStore(), deviceId: "test-strap",
                                      log: { lines.append($0) }, now: { 1_750_000_000 })
            collector.ingestStandardHR(hr: 250, rr: [800], at: 1_750_000_000)
            XCTAssertTrue(lines.contains { $0.contains("host-received") && $0.contains("rejectedHRRows=1") },
                          lines.joined(separator: "\n"))
        }
    }
}
