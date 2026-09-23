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

    func testAFasterStrapNeverLetsTheTraceFallBehindOrGoBlank() {
        // 125 samples per record at one record per second: 25 % faster than the playback rate.
        var feed = EcgLiveFeed()
        for k in 0..<90 {
            let at = t0.addingTimeInterval(Double(k))
            feed.append(record(UInt32(k + 1), samples: Array(repeating: k, count: 125)), at: at)
            let backlog = feed.totalSamples - feed.displayedEnd(at: at)
            XCTAssertLessThanOrEqual(backlog, EcgLiveFeed.maxBacklog + 125, "record \(k)")
            XCTAssertFalse(feed.window(endingAt: at.addingTimeInterval(0.5), count: 400).isEmpty, "record \(k)")
        }
        // At the 90 s cap the trace is drawing samples from the last few records, not from 20 s ago.
        let end = t0.addingTimeInterval(89.5)
        XCTAssertGreaterThanOrEqual(feed.window(endingAt: end, count: 1).first ?? -1, 86)
    }

    func testAFasterStrapNeverFreezesAfterASkip() {
        // The old skip left only the pre-roll undrawn, so the trace ran dry 0.4 s later and froze for about
        // a second after every skip. 125 samples a second, delivered two ways; after warm-up every 0.1 s of
        // wall time must draw something new.
        for (perRecord, interval) in [(100, 0.8), (125, 1.0)] {
            var feed = EcgLiveFeed()
            var index: UInt32 = 0
            var previous = 0
            for step in 0..<600 {
                let t = Double(step) / 10
                while Double(index) * interval <= t + 1e-9 {
                    feed.append(record(index + 1, samples: Array(repeating: 0, count: perRecord)),
                                at: t0.addingTimeInterval(Double(index) * interval))
                    index += 1
                }
                let end = feed.displayedEnd(at: t0.addingTimeInterval(t))
                if t >= 3 { XCTAssertGreaterThan(end, previous, "\(perRecord) per \(interval) s stalled at \(t) s") }
                previous = end
            }
        }
    }

    func testASkippedRecordIndexBreaksTheTraceWhereItHappened() {
        var feed = EcgLiveFeed()
        feed.append(record(1, samples: Array(0..<100)), at: t0)
        feed.append(record(2, samples: Array(100..<200)), at: t0.addingTimeInterval(1))
        feed.append(record(4, samples: Array(200..<300)), at: t0.addingTimeInterval(2))
        XCTAssertEqual(feed.gapAfterSamples, [199])
        let end = t0.addingTimeInterval(3.4)   // 300 samples drawn
        XCTAssertEqual(feed.window(endingAt: end, count: 150), Array(150..<300))
        XCTAssertEqual(feed.gapsInWindow(endingAt: end, count: 150), [49])
        // Drawn only up to the gap: there is nothing after it to break from.
        XCTAssertEqual(feed.gapsInWindow(endingAt: t0.addingTimeInterval(2.4), count: 150), [])
    }

    func testAGapIsForgottenOnceItsSampleIsTrimmed() {
        var feed = EcgLiveFeed(capacity: 150)
        feed.append(record(1, samples: Array(0..<100)), at: t0)
        feed.append(record(3, samples: Array(100..<200)), at: t0)
        XCTAssertEqual(feed.gapAfterSamples, [99])
        feed.append(record(4, samples: Array(200..<300)), at: t0)
        XCTAssertEqual(feed.gapAfterSamples, [])
    }

    func testAnOnTimeStrapNeverSkips() {
        var feed = EcgLiveFeed()
        for k in 0..<30 {
            feed.append(record(UInt32(k + 1), samples: Array(0..<100).map { $0 + k * 100 }),
                        at: t0.addingTimeInterval(Double(k)))
        }
        // Continuous playback from the first anchor: 29.5 s after it, sample 2950 is drawn.
        XCTAssertEqual(feed.displayedEnd(at: t0.addingTimeInterval(29.9)), 2_950)
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
