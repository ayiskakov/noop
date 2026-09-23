import XCTest
import StrandAnalytics
import WhoopStore
@testable import Strand

/// A partial first day or a since-dropped session must not leave a score behind: the weekly Vitality /
/// Body Age needs enough scored nights, and a `sleep_performance` point whose day lost its sleep is stale.
final class StaleWeeklyAndRestPointTests: XCTestCase {

    private func day(_ key: String, rhr: Int?, sleepMin: Double? = nil) -> DailyMetric {
        DailyMetric(day: key, totalSleepMin: sleepMin, efficiency: sleepMin == nil ? nil : 0.9,
                    deepMin: nil, remMin: nil, lightMin: nil, disturbances: nil,
                    restingHr: rhr, avgHrv: rhr == nil ? nil : 50, recovery: nil, strain: nil,
                    exerciseCount: nil, spo2Pct: nil, skinTempDevC: nil, respRateBpm: nil, steps: 672,
                    activeKcalEst: nil, spo2Red: nil, spo2Ir: nil, avgSdnn: nil, skinTempC: nil,
                    sleepHrOnly: nil)
    }

    func testOneScoredNightIsNotAWeeklyBodyAge() {
        let week = [day("2026-09-18", rhr: 60)]
        XCTAssertFalse(IntelligenceEngine.healthspanWeekIsScorable(week))
        let three = (19...21).map { day("2026-09-\($0)", rhr: 52) } + [day("2026-09-22", rhr: nil)]
        XCTAssertFalse(IntelligenceEngine.healthspanWeekIsScorable(three))
        let four = (19...22).map { day("2026-09-\($0)", rhr: 52) }
        XCTAssertTrue(IntelligenceEngine.healthspanWeekIsScorable(four))
    }

    func testRestPointForADayWithoutSleepIsStale() {
        let persisted = [day("2026-09-18", rhr: nil), day("2026-09-19", rhr: 53, sleepMin: 520)]
        let produced = [MetricPoint(day: "2026-09-19", key: "sleep_performance", value: 90),
                        MetricPoint(day: "2026-09-18", key: "zone_min_2_3", value: 75)]
        XCTAssertEqual(IntelligenceEngine.staleRestPointDays(persisted: persisted, produced: produced),
                       ["2026-09-18"])
    }
}
