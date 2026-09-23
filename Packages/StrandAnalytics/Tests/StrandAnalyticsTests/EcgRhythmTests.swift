import XCTest
import WhoopProtocol
@testable import StrandAnalytics

/// The rhythm facts are measurements over a known interval series, so each expected value here is
/// worked by hand from the series the test builds.
final class EcgRhythmTests: XCTestCase {

    /// A result whose stretches carry exactly these intervals, in milliseconds, rejected ones included.
    private func result(_ stretches: [[Double]]) -> EcgBeats.Result {
        let intervals = stretches.enumerated().flatMap { s, ms in ms.map { EcgBeats.Interval(ms: $0, segment: s) } }
        return EcgBeats.Result(beats: [], intervals: intervals,
                               analysedSeconds: Int(intervals.reduce(0) { $0 + $1.ms } / 1_000))
    }

    private func facts(_ stretches: [[Double]], records: [EcgCandidateSample] = []) -> EcgRhythmFacts {
        EcgRhythmFacts.from(result(stretches), records: records)!
    }

    func testASteadySixtyHasNoVariationAndIsNeitherHighNorLow() {
        let f = facts([Array(repeating: 1_000, count: 20)])
        XCTAssertEqual(f.heartRate, 60, accuracy: 1e-9)
        XCTAssertEqual(f.rateLow, 60, accuracy: 1e-9)
        XCTAssertEqual(f.rateHigh, 60, accuracy: 1e-9)
        XCTAssertEqual(f.fractionAboveHigh, 0)
        XCTAssertEqual(f.fractionBelowLow, 0)
        XCTAssertEqual(f.variationPercent, 0, accuracy: 1e-9)
        XCTAssertEqual(try XCTUnwrap(f.rmssdMs), 0, accuracy: 1e-9)
        XCTAssertEqual(f.setAsideIntervals, 0)
    }

    func testHighAndLowAreSharesOfTheRollingRate() {
        XCTAssertEqual(facts([Array(repeating: 500, count: 20)]).fractionAboveHigh, 1)      // 120 bpm
        XCTAssertEqual(facts([Array(repeating: 1_500, count: 20)]).fractionBelowLow, 1)     // 40 bpm
        // 10 intervals at 120 bpm then 10 at 75: of the 16 five-interval windows, window k holds
        // min(5, 10 − k) intervals of 500 ms, and its median is 500 when that is at least 3 — k = 0…7.
        let mixed = facts([Array(repeating: 500, count: 10) + Array(repeating: 800, count: 10)])
        XCTAssertEqual(mixed.fractionAboveHigh, 8.0 / 16.0, accuracy: 1e-12)
        XCTAssertEqual(mixed.fractionBelowLow, 0)
    }

    func testAlternatingIntervalsGiveTheirKnownRmssdAndVariation() {
        // 800/840 alternating: every successive difference is 40 ms, so RMSSD = 40. Mean 820, sample SD
        // over 20 values = 20 · √(20/19).
        let f = facts([(0..<20).map { $0 % 2 == 0 ? 800 : 840 }])
        XCTAssertEqual(try XCTUnwrap(f.rmssdMs), 40, accuracy: 1e-9)
        XCTAssertEqual(f.variationPercent, 20 * (20.0 / 19).squareRoot() / 820 * 100, accuracy: 1e-9)
    }

    func testADoubledBeatIsSetAsideAndDoesNotEnterRmssd() {
        // A false extra detection splits one 800 ms gap into 400 + 400.
        let f = facts([Array(repeating: 800, count: 10) + [400, 400] + Array(repeating: 800, count: 10)])
        XCTAssertEqual(f.setAsideIntervals, 2)
        XCTAssertEqual(try XCTUnwrap(f.rmssdMs), 0, accuracy: 1e-9)
        XCTAssertEqual(f.heartRate, 75, accuracy: 1e-9)
    }

    func testNoDifferenceIsTakenAcrossTwoStretches() {
        // Each stretch is perfectly steady; only a cross-stretch pair would differ.
        let f = facts([Array(repeating: 800, count: 10), Array(repeating: 600, count: 10)])
        XCTAssertEqual(try XCTUnwrap(f.rmssdMs), 0, accuracy: 1e-9)
        // Nor is the difference in rate between them counted as variation (pooled over both it is 14.6 %).
        XCTAssertEqual(f.variationPercent, 0, accuracy: 1e-9)
    }

    func testNoDifferenceIsTakenAcrossARejectedInterval() {
        // A missed beat leaves one 2,200 ms interval, out of range, between a steady 1,180 and a steady
        // 1,000. The two sides were never adjacent, so no difference joins them.
        let f = facts([Array(repeating: 1_180, count: 6) + [2_200] + Array(repeating: 1_000, count: 6)])
        XCTAssertEqual(try XCTUnwrap(f.rmssdMs), 0, accuracy: 1e-9)
        XCTAssertEqual(f.setAsideIntervals, 0)
    }

    func testVariationIsPooledWithinStretches() {
        // Two stretches alternating by 40 ms around different rates. Each has sample SD 20 · √(20/19), so
        // the pooled SD is the same; the mean of all forty intervals is 720.
        let f = facts([(0..<20).map { $0 % 2 == 0 ? 800 : 840 }, (0..<20).map { $0 % 2 == 0 ? 600 : 640 }])
        XCTAssertEqual(f.variationPercent, 20 * (20.0 / 19).squareRoot() / 720 * 100, accuracy: 1e-9)
        XCTAssertEqual(try XCTUnwrap(f.rmssdMs), 40, accuracy: 1e-9)
    }

    func testTheRangeTakesInTheRate() {
        // Eight uneven intervals: the median of all of them (847 ms, 70.8 bpm) lies outside the 5th–95th
        // percentiles of their four five-interval windows (67.5–68.3 bpm).
        let f = facts([[889, 656, 805, 896, 905, 878, 746, 816]])
        XCTAssertEqual(f.heartRate, 60_000 / 847, accuracy: 1e-9)
        XCTAssertLessThanOrEqual(f.rateLow, f.heartRate)
        XCTAssertEqual(f.rateHigh, f.heartRate, accuracy: 1e-9)
    }

    func testTooFewIntervalsGiveNoFacts() {
        XCTAssertNil(EcgRhythmFacts.from(result([Array(repeating: 800, count: 5)]), records: []))
    }

    func testTheStrapCodeComesFromTheFirstCompletedRecordAndIsKeptRaw() {
        let records = [
            EcgCandidateSample(ts: 3, samples: [], classifierResult: 0, classifierState: 1),
            EcgCandidateSample(ts: 5, samples: [], classifierResult: 5, classifierState: 2),
            EcgCandidateSample(ts: 6, samples: [], classifierResult: 2, classifierState: 2),
        ]
        XCTAssertEqual(facts([Array(repeating: 800, count: 10)], records: records).strapResultCode, 5)
        XCTAssertNil(facts([Array(repeating: 800, count: 10)], records: [records[0]]).strapResultCode)
    }
}
