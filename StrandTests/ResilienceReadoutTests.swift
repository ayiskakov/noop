import XCTest
@testable import Strand
import StrandAnalytics
import WhoopStore

/// The Resilience section's own decisions on top of `ResilienceEngine`: which days each signal reads, where
/// its window ends, that the trend ends on the headline itself, and how a range is worded.
final class ResilienceReadoutTests: XCTestCase {

    private func metric(_ day: String, steps: Int? = nil, rhr: Int? = nil, hrv: Double? = nil) -> DailyMetric {
        DailyMetric(day: day, totalSleepMin: nil, efficiency: nil, deepMin: nil, remMin: nil, lightMin: nil,
                    disturbances: nil, restingHr: rhr, avgHrv: hrv, recovery: nil, strain: nil,
                    exerciseCount: nil, steps: steps)
    }

    /// Each signal reads its own column; a day without it is missing, not zero.
    func testSeriesReadsEachSignalsColumnAndSkipsMissingDays() {
        let days = [metric("2026-01-01", steps: 8000, rhr: 55), metric("2026-01-02", hrv: 60),
                    metric("2026-01-03", steps: 0)]
        let steps = ResilienceLoader.series(days, signal: .steps)
        XCTAssertEqual(steps.map(\.value), [8000, 0])
        XCTAssertEqual(steps.map(\.dayIndex), [PaceOfAgingEngine.dayIndex("2026-01-01")!,
                                               PaceOfAgingEngine.dayIndex("2026-01-03")!])
        XCTAssertEqual(ResilienceLoader.series(days, signal: .restingHR).map(\.value), [55])
        XCTAssertEqual(ResilienceLoader.series(days, signal: .hrv).map(\.value), [60])
    }

    /// Today's step total is still counting, so steps stop at yesterday; the overnight signals do not.
    func testStepsEndYesterdayAndTheOvernightSignalsToday() {
        XCTAssertEqual(ResilienceLoader.endDay(.steps, today: 100), 99)
        XCTAssertEqual(ResilienceLoader.endDay(.restingHR, today: 100), 100)
        XCTAssertEqual(ResilienceLoader.endDay(.hrv, today: 100), 100)
    }

    func testTrendEndDaysEndExactlyOnTheHeadlineDay() {
        let ends = ResilienceLoader.trendEndDays(1000)
        XCTAssertEqual(ends.last, 1000)
        XCTAssertEqual(ends.first, 1000 - 26 * ResilienceLoader.trendStepDays)
        XCTAssertEqual(ends, ends.sorted())
        XCTAssertTrue(zip(ends, ends.dropFirst()).allSatisfy { $1 - $0 == ResilienceLoader.trendStepDays })
    }

    /// The chart's newest point IS the hero's estimate, passed through rather than recomputed.
    func testTheTrendEndsOnTheHeadlineEstimate() async throws {
        let series = (0..<100).map { ResilienceEngine.DayValue(dayIndex: $0, value: 55 + Double(($0 * 37) % 11) - 5) }
        let result = ResilienceEngine.analyze(series: series, signal: .restingHR, endDay: 99, replicates: 4)
        let readout = ResilienceReadout(signal: .restingHR, endDay: 99, result: result, knocks: [], series: series)
        // Every earlier window holds fewer than 90 days, so only the headline survives.
        let trend = await ResilienceLoader.trend(readout)
        XCTAssertEqual(trend.count, 1)
        XCTAssertEqual(trend.last?.endDay, 99)
        XCTAssertEqual(trend.last?.estimate, try XCTUnwrap(result?.estimate))
    }

    private func estimate(tau: Double, low: Double, high: Double, amplitude: Double = 0.5) -> ResilienceEngine.Estimate {
        ResilienceEngine.Estimate(tau: tau, tauLow: low, tauHigh: high, tauFit: tau, amplitude: amplitude,
                                  sigma: 0.3, acf: [], acfPairs: [])
    }

    func testRangeWording() {
        XCTAssertEqual(ResilienceFormat.range(estimate(tau: 16, low: 10.6, high: 24.4)), "90 % range: 11–24 days")
        // An upper bound at the ceiling cannot rule anything longer out.
        XCTAssertEqual(ResilienceFormat.range(estimate(tau: 40, low: 12, high: 180)), "90 % range: 12 days or longer")
        XCTAssertEqual(ResilienceFormat.headline(estimate(tau: 1.2, low: 1, high: 3)), "≈ 1 day")
        XCTAssertEqual(ResilienceFormat.headline(estimate(tau: 15.6, low: 9, high: 30)), "≈ 16 days")
    }

    func testChipValueStates() {
        let collecting = ResilienceReadout(
            signal: .steps, endDay: 10,
            result: ResilienceEngine.Result(signal: .steps, endDay: 10, observedDays: 40, daysUntilReady: 50, estimate: nil),
            knocks: [], series: [])
        XCTAssertEqual(ResilienceFormat.chipValue(collecting), "40/90 days")
        let flat = ResilienceReadout(
            signal: .steps, endDay: 10,
            result: ResilienceEngine.Result(signal: .steps, endDay: 10, observedDays: 120, daysUntilReady: 0,
                                            estimate: estimate(tau: 1, low: 1, high: 180, amplitude: 0.02)),
            knocks: [], series: [])
        XCTAssertEqual(ResilienceFormat.chipValue(flat), "No carry-over")
    }

    /// The log signals' σ reads as a percentage swing; resting HR's stays in bpm.
    func testSigmaInTheSignalsOwnTerms() {
        XCTAssertEqual(ResilienceFormat.sigmaValue(log(1.25), signal: .steps), 25, accuracy: 1e-9)
        XCTAssertEqual(ResilienceFormat.sigmaValue(2.4, signal: .restingHR), 2.4)
    }

    func testOnlyStepsIsLabelledPublished() {
        XCTAssertEqual(ResilienceFormat.provenance(.steps), "Published")
        XCTAssertEqual(ResilienceFormat.provenance(.restingHR), "Extension")
        XCTAssertEqual(ResilienceFormat.provenance(.hrv), "Extension")
    }
}
