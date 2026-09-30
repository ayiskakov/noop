import XCTest
import WhoopProtocol
@testable import StrandAnalytics

/// W03-007 — a reading is only as good as the seconds behind it.
///
/// On a night the strap sat loose, byte 82's 30-second readings come back mixed with the strap's own
/// non-percentage codes, and the few in-band seconds left between them are fragments that jump. Taken at
/// face value those readings became the night's low and its dips. These cases are synthetic, shaped like
/// the owner's 2026-09-29 and 2026-09-30 nights (no values copied from them).
final class Spo2CandidateQualityTests: XCTestCase {

    private func sess(_ s: Int, _ d: Int) -> SleepSession {
        SleepSession(start: s, end: s + d, efficiency: 0.9, stages: [], restingHR: 50, avgHRV: 60)
    }
    private func aux(_ ts: Int, _ v: Int?) -> V18AuxSample { V18AuxSample(ts: ts, auxByte82: v) }
    /// One reading: `values[i]` at `start + i`, 30 seconds for the strap's real window shape.
    private func reading(_ start: Int, _ values: [Int]) -> [V18AuxSample] {
        values.enumerated().map { aux(start + $0.offset, $0.element) }
    }

    /// A clean reading, as a well-fitted strap reports one.
    private let clean = [95, 95, 96, 96, 96, 95, 95, 95, 96, 96, 96, 96, 95, 95, 95,
                         96, 96, 96, 95, 95, 95, 96, 96, 96, 96, 95, 95, 95, 96, 96]
    /// Half codes: a steady low run broken up by the codes a loose strap interleaves.
    private let fragmented = [32, 32, 32, 160, 74, 74, 72, 74, 74, 75, 74, 74, 73, 73, 71,
                              160, 160, 160, 74, 32, 32, 32, 75, 128, 128, 128, 72, 73, 128, 128]
    /// Enough seconds, but they sweep across the band instead of agreeing on a value.
    private let sweep = [128, 1, 128, 128, 128, 128, 128, 128, 84, 83, 88, 32, 83, 32, 75,
                         72, 71, 72, 81, 90, 96, 99, 100, 100, 99, 100, 100, 100, 100, 100]

    /// V0: the loose-strap night. Two of its readings are low-quality; neither may become a dip or the
    /// night's low, and the average rests on the clean readings alone.
    func testLowQualityReadingsAreNotDipsAndDoNotMoveTheNight() {
        let aux = reading(0, clean) + reading(1200, fragmented) + reading(2400, sweep) + reading(3600, clean)
        let n = AnalyticsEngine.nightlySpo2CandidateNight([sess(0, 5000)], aux: aux)
        XCTAssertEqual(n?.events.count, 0)
        XCTAssertEqual(n?.minimum, 96)
        XCTAssertEqual(n?.windows, 2)
        XCTAssertEqual(n?.windowsAttempted, 4)
        XCTAssertEqual(n?.windowsLowCoverage, 1)
        XCTAssertEqual(n?.windowsUnsettled, 1)
    }

    /// The gate judges what the strap reported, never whether the value is low. A steady, well-covered
    /// low reading stays a low reading: a filter tuned on the outcome would hide the nights it is for.
    func testASteadyWellCoveredLowReadingStaysALowReading() {
        let steadyLow = (0..<30).map { 86 + $0 % 3 }
        let n = AnalyticsEngine.nightlySpo2CandidateNight(
            [sess(0, 3000)], aux: reading(0, clean) + reading(1200, steadyLow))
        XCTAssertEqual(n?.events.count, 1)
        XCTAssertEqual(n?.minimum, 87)
        XCTAssertEqual(n?.windowsLowQuality, 0)
    }

    /// A night on which the strap attempted readings and none was reliable is NOT nil: it is a night
    /// with no reliable reading, which is exactly what a surface needs to say.
    func testANightOfFailedReadingsIsStatedNotDropped() {
        let n = AnalyticsEngine.nightlySpo2CandidateNight(
            [sess(0, 3000)], aux: reading(0, fragmented) + reading(1200, sweep))
        XCTAssertNotNil(n)
        XCTAssertNil(n?.mean)
        XCTAssertNil(n?.minimum)
        XCTAssertEqual(n?.windowsAttempted, 2)
        XCTAssertEqual(n?.windowsLowQuality, 2)
        XCTAssertTrue(n!.events.isEmpty)
        XCTAssertNil(AnalyticsEngine.nightlySpo2CandidateMean([sess(0, 3000)],
                                                              aux: reading(0, fragmented)),
                     "the legacy integer mean has no answer either")
    }

    /// The chart's seconds and the night's figures are cut by the same windows and the same verdict: the
    /// trace holds exactly the reliable readings' in-band seconds, so it cannot draw a low the tiles left
    /// out.
    func testTheTraceHoldsOnlyTheReliableReadingsSeconds() {
        let aux = reading(0, clean) + reading(1200, fragmented) + reading(2400, sweep)
        let trace = AnalyticsEngine.spo2CandidateReliableSeconds([sess(0, 3000)], aux: aux)
        let night = AnalyticsEngine.nightlySpo2CandidateNight([sess(0, 3000)], aux: aux)
        XCTAssertEqual(trace.count, night?.samples)
        XCTAssertEqual(trace.map(\.ts), Array(0..<30))
        XCTAssertEqual(trace.map(\.value).min(), 95)
    }
}
