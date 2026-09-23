import XCTest
@testable import StrandAnalytics

/// `Baselines.priorFold` scores each day against the nights BEFORE it: its state for a day must equal a
/// plain `foldHistory` over exactly the earlier keys, epoch drop included.
final class BaselinesPriorFoldTests: XCTestCase {
    private let cfg = Baselines.metricCfg["hrv"]!
    private let keys = ["2026-09-18", "2026-09-19", "2026-09-20", "2026-09-21", "2026-09-22", "2026-09-23"]
    private let values: [Double?] = [44.9, 48.8, nil, 52.6, 55.5, 51.1]

    func testStateBeforeEachDayMatchesAFoldOfTheEarlierNightsOnly() {
        let prior = Baselines.priorFold(values, dayKeys: keys, cfg: cfg, baselineEpoch: 0)
        for (i, day) in keys.enumerated() where i > 0 {
            XCTAssertEqual(prior.state(before: day),
                           Baselines.foldHistory(Array(values[0..<i]), dayKeys: Array(keys[0..<i]), cfg: cfg,
                                                 baselineEpoch: 0), "day \(day)")
        }
        // After the last key the prior state is the whole-history fold.
        XCTAssertEqual(prior.state(before: "2026-09-24"),
                       Baselines.foldHistory(values, dayKeys: keys, cfg: cfg, baselineEpoch: 0))
    }

    func testNothingPrecedingIsTheCalibratingSeed() {
        let prior = Baselines.priorFold(values, dayKeys: keys, cfg: cfg, baselineEpoch: 0)
        let first = prior.state(before: keys[0])
        XCTAssertEqual(first.nValid, 0)
        XCTAssertFalse(first.usable)
        XCTAssertEqual(first, Baselines.foldHistory([], dayKeys: [], cfg: cfg, baselineEpoch: 0))
    }

    func testADayNeverSeesItsOwnNightOrLaterOnes() {
        // Changing the scored night or any later one cannot move the baseline it is scored against.
        var future = values
        future[3] = 90; future[4] = 20; future[5] = 99
        let a = Baselines.priorFold(values, dayKeys: keys, cfg: cfg, baselineEpoch: 0)
        let b = Baselines.priorFold(future, dayKeys: keys, cfg: cfg, baselineEpoch: 0)
        XCTAssertEqual(a.state(before: "2026-09-21"), b.state(before: "2026-09-21"))
    }

    func testFourPriorNightsAreNeededBeforeTheBaselineIsUsable() {
        let prior = Baselines.priorFold([50, 51, 49, 52, 50], dayKeys: Array(keys.prefix(5)), cfg: cfg,
                                        baselineEpoch: 0)
        XCTAssertFalse(prior.state(before: "2026-09-21").usable, "3 prior nights")
        XCTAssertTrue(prior.state(before: "2026-09-22").usable, "4 prior nights")
    }

    func testRecalibrationEpochDropsEarlierNightsLikeFoldHistory() {
        let epoch = Double(Calendar(identifier: .gregorian).date(
            from: DateComponents(timeZone: TimeZone(secondsFromGMT: 0), year: 2026, month: 9, day: 20))!
            .timeIntervalSince1970)
        let prior = Baselines.priorFold(values, dayKeys: keys, cfg: cfg, baselineEpoch: epoch)
        XCTAssertEqual(prior.state(before: "2026-09-24"),
                       Baselines.foldHistory(values, dayKeys: keys, cfg: cfg, baselineEpoch: epoch))
    }
}
