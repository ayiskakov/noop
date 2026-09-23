import XCTest
import WhoopProtocol
@testable import StrandAnalytics

/// The live ECG jitter buffer: dedup, gap counting, capacity, and the pacing a sweeping trace reads.
final class EcgLiveFeedTests: XCTestCase {

    private let t0 = Date(timeIntervalSince1970: 1_790_000_000)

    private func record(_ index: UInt32, samples: [Int], quality: UInt8 = 3,
                        stateBits: UInt8 = 0x08, progress: UInt8 = 10) -> Whoop5EcgFilteredRecord.Decoded {
        let status = Whoop5EcgRawRecord.Status(quality: quality, stateBits: stateBits, classifierResult: 0,
                                               classifierState: 1, progress: progress, packedBooleans: 0,
                                               hrRelated: 0, hrRelatedR17: 0, hrvRelated: 0xFFFF,
                                               reservedZero: 0, declaredSampleCount: UInt16(samples.count))
        return .init(recordIndex: index, unix: 1_790_000_000 + index, status: status,
                     samples: samples, anomalies: [])
    }

    func testNothingIsDrawnDuringThePrerollThenItAdvancesAtThePlaybackRate() {
        var feed = EcgLiveFeed()
        feed.append(record(1, samples: Array(0..<100)), at: t0)
        XCTAssertEqual(feed.displayedEnd(at: t0), 0)
        XCTAssertEqual(feed.displayedEnd(at: t0.addingTimeInterval(0.4)), 0)
        XCTAssertEqual(feed.displayedEnd(at: t0.addingTimeInterval(0.9)), 50)
        // Never past what has arrived.
        XCTAssertEqual(feed.displayedEnd(at: t0.addingTimeInterval(5)), 100)
    }

    func testAnOnTimeBurstContinuesWithoutReanchoring() {
        var feed = EcgLiveFeed()
        feed.append(record(1, samples: Array(0..<100)), at: t0)
        feed.append(record(2, samples: Array(100..<200)), at: t0.addingTimeInterval(1.0))
        // 1.9 s: 1.5 s after the anchor at 0.4 s → 150 samples, straight through the burst boundary.
        XCTAssertEqual(feed.displayedEnd(at: t0.addingTimeInterval(1.9)), 150)
    }

    func testALateBurstResumesFromTheStallInsteadOfJumping() {
        var feed = EcgLiveFeed()
        feed.append(record(1, samples: Array(0..<100)), at: t0)
        // The trace ran dry at 1.4 s; the next burst lands at 3.0 s.
        feed.append(record(2, samples: Array(100..<200)), at: t0.addingTimeInterval(3.0))
        XCTAssertEqual(feed.displayedEnd(at: t0.addingTimeInterval(3.0)), 100)
        XCTAssertEqual(feed.displayedEnd(at: t0.addingTimeInterval(3.9)), 150)
    }

    func testARepeatedRecordIndexIsDroppedAndAForwardSkipIsCounted() {
        var feed = EcgLiveFeed()
        XCTAssertTrue(feed.append(record(10, samples: [1, 2]), at: t0))
        XCTAssertFalse(feed.append(record(10, samples: [1, 2]), at: t0))
        feed.append(record(13, samples: [3]), at: t0)
        // A lower index is a new session, not a hole.
        feed.append(record(2, samples: [4]), at: t0)
        XCTAssertEqual(feed.records, 3)
        XCTAssertEqual(feed.duplicates, 1)
        XCTAssertEqual(feed.gaps, 1)
        XCTAssertEqual(feed.totalSamples, 4)
    }

    func testStatusIsTheNewestRecords() {
        var feed = EcgLiveFeed()
        feed.append(record(1, samples: [0], quality: 0, stateBits: 0x03, progress: 0), at: t0)
        XCTAssertEqual(feed.status?.presence, false)
        feed.append(record(2, samples: [0], quality: 3, stateBits: 0x0A, progress: 40), at: t0)
        XCTAssertEqual(feed.status?.quality, 3)
        XCTAssertEqual(feed.status?.presence, true)
        XCTAssertEqual(feed.status?.progress, 40)
    }

    func testCapacityKeepsTheNewestAndTheWindowIndexesAcrossTheTrim() {
        var feed = EcgLiveFeed(capacity: 150)
        feed.append(record(1, samples: Array(0..<100)), at: t0)
        feed.append(record(2, samples: Array(100..<200)), at: t0.addingTimeInterval(1.0))
        XCTAssertEqual(feed.samples.count, 150)
        XCTAssertEqual(feed.samples.first, 50)
        let end = t0.addingTimeInterval(2.4)   // 200 samples drawn
        XCTAssertEqual(feed.window(endingAt: end, count: 10), Array(190..<200))
        // Asking for more than is kept returns what is kept, never an index before the trim.
        XCTAssertEqual(feed.window(endingAt: end, count: 1_000), Array(50..<200))
        XCTAssertEqual(feed.window(endingAt: t0, count: 10), [])
    }
}
