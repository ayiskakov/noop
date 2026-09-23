import XCTest
@testable import Strand
import StrandAnalytics
import WhoopStore

/// The orchestration half of Healthspan: how the analytics pass turns stored history into
/// `VitalityEngine.Inputs` for each window, and into the per-day points the screens read.
///
/// The engines themselves are covered in the StrandAnalytics package, against a committed oracle. What is
/// only testable here is the ASSEMBLY: which days count as observed, how a partial window is scaled to a
/// weekly dose, which windows each point reads, and when a day is unlocked at all.
final class HealthspanInputsTests: XCTestCase {

    private let today = PaceOfAgingEngine.dayIndex("2026-09-23")!

    /// A day carrying enough for every non-activity driver, so the assembly under test is the only variable.
    private func day(_ index: Int, rhr: Int? = 60, sleepMin: Double = 450, steps: Int = 8000) -> DailyMetric {
        DailyMetric(day: IntelligenceEngine.healthspanDayKey(index, IntelligenceEngine.healthspanDayFormatter()),
                    totalSleepMin: sleepMin, efficiency: nil, deepMin: nil, remMin: nil,
                    lightMin: nil, disturbances: nil, restingHr: rhr, avgHrv: 40, recovery: nil,
                    strain: nil, exerciseCount: nil, steps: steps)
    }

    /// `count` consecutive days ending on `end`, every one worn.
    private func history(days count: Int, end: Int? = nil,
                         _ edit: (Int, inout HealthspanHistory) -> Void = { _, _ in }) -> HealthspanHistory {
        let last = end ?? today
        var h = HealthspanHistory()
        for i in (last - count + 1)...last { h.days[i] = day(i); edit(i, &h) }
        return h
    }

    private func inputs(_ h: HealthspanHistory, window: Int, end: Int? = nil) -> VitalityEngine.Inputs {
        IntelligenceEngine.healthspanInputs(history: h, endDay: end ?? today, windowDays: window,
                                            age: 40, sex: "male", profileWeightKg: 80)
    }

    // MARK: - Dose assembly

    /// Five observed days of 20 zone-1–3 minutes is a 140-minute WEEK: doses are stated per week whatever
    /// coverage the window had.
    func testPartialWindowScalesToASevenDayDose() throws {
        let h = history(days: 7) { i, h in if i > self.today - 5 { h.zones[i] = (20, 5) } }
        let x = inputs(h, window: 7)
        XCTAssertEqual(try XCTUnwrap(x.moderateMinPerWeek), 140, accuracy: 1e-9)
        XCTAssertEqual(try XCTUnwrap(x.vigorousMinPerWeek), 35, accuracy: 1e-9)
    }

    /// Below the coverage floor there is no dose at all: one logged day is not a week.
    func testTooFewObservedDaysYieldsNoDose() {
        let h = history(days: 30) { i, h in if i > self.today - 3 { h.zones[i] = (60, 30); h.strength[i] = 45 } }
        let x = inputs(h, window: 30)
        XCTAssertNil(x.moderateMinPerWeek)
        XCTAssertNil(x.strengthMinPerWeek)
        XCTAssertNotNil(x.restingHR, "a thin activity window still has a resting HR")
    }

    /// A WATCHED day with no strength entry did no strength training — zero, not unknown.
    func testAWatchedDayWithNoStrengthCountsAsZero() throws {
        let h = history(days: 14) { i, h in
            h.zones[i] = (10, 0)
            if i == self.today - 3 { h.strength[i] = 70 }
        }
        XCTAssertEqual(try XCTUnwrap(inputs(h, window: 14).strengthMinPerWeek), 35, accuracy: 1e-9)
    }

    // MARK: - The other drivers

    /// Regularity comes from the SRI agreement pairs inside the window, not from durations.
    func testRegularityReadsTheWindowsPairs() throws {
        let h = history(days: 40) { i, h in h.sriAgreement[i] = i > self.today - 10 ? 1.0 : 0.5 }
        XCTAssertEqual(try XCTUnwrap(inputs(h, window: 7).sleepRegularity), 100, accuracy: 1e-9)
        XCTAssertEqual(try XCTUnwrap(inputs(h, window: 30).sleepRegularity), 200 * ((9 + 21 * 0.5) / 30) - 100,
                       accuracy: 1e-9)
    }

    /// An imported VO₂max is independent evidence and wins over the strap's estimate in its window.
    func testExternalVO2maxWinsInItsWindow() {
        let h = history(days: 60) { i, h in
            if (i - self.today) % 7 == 0 { h.vo2max[i] = (40, .strap) }
            if i == self.today - 40 { h.vo2max[i] = (50, .external) }
        }
        let recent = inputs(h, window: 30), baseline = inputs(h, window: 60)
        XCTAssertEqual(recent.vo2max, 40)
        XCTAssertEqual(recent.vo2maxSource, .strap)
        XCTAssertEqual(baseline.vo2max, 50)
        XCTAssertEqual(baseline.vo2maxSource, .external)
    }

    /// Lean mass needs a weight; the window's own readings win over the profile weight.
    func testLeanMassUsesTheWindowsWeight() {
        let h = history(days: 30) { i, h in
            if i == self.today - 2 { h.leanMass[i] = 60; h.weight[i] = 75 }
        }
        let x = inputs(h, window: 30)
        XCTAssertEqual(x.leanMassKg, 60)
        XCTAssertEqual(x.weightKg, 75)
        XCTAssertNil(inputs(history(days: 30), window: 30).weightKg, "no lean mass → no weight carried")
    }

    // MARK: - Points

    /// Locked below 21 scored days in the last 31; unlocked at 21.
    func testUnlockGate() {
        XCTAssertTrue(IntelligenceEngine.healthspanPoints(
            history: history(days: 20), endDay: today, dayKey: "2026-09-23",
            age: 40, sex: "male", profileWeightKg: 80).isEmpty)
        XCTAssertFalse(IntelligenceEngine.healthspanPoints(
            history: history(days: 21), endDay: today, dayKey: "2026-09-23",
            age: 40, sex: "male", profileWeightKg: 80).isEmpty)
        XCTAssertTrue(IntelligenceEngine.healthspanPoints(
            history: history(days: 60), endDay: today, dayKey: "2026-09-23",
            age: 17, sex: "male", profileWeightKg: 80).isEmpty, "adults only")
    }

    /// The persisted per-driver years sum to the persisted Body Age offset — the property that lets a
    /// screen show years per driver without recomputing anything.
    func testPersistedDriverYearsSumToTheHeadline() throws {
        let h = history(days: 200) { i, h in
            h.zones[i] = (40, 2); h.strength[i] = i % 7 == 0 ? 30 : 0; h.sriAgreement[i] = 0.9
        }
        let points = IntelligenceEngine.healthspanPoints(history: h, endDay: today, dayKey: "2026-09-23",
                                                         age: 40, sex: "male", profileWeightKg: 80)
        let byKey = Dictionary(uniqueKeysWithValues: points.map { ($0.key, $0.value) })
        let years = HealthspanSeries.drivers.compactMap { byKey[HealthspanSeries.years($0)] }
        XCTAssertGreaterThanOrEqual(years.count, 6)
        XCTAssertEqual(years.reduce(0, +), try XCTUnwrap(byKey[HealthspanSeries.bodyAge]) - 40, accuracy: 1e-9)
        XCTAssertNotNil(byKey[HealthspanSeries.pace])
        XCTAssertNotNil(byKey[HealthspanSeries.paceMargin])
        XCTAssertEqual(try XCTUnwrap(byKey[HealthspanSeries.projectedBodyAge]),
                       try XCTUnwrap(byKey[HealthspanSeries.bodyAge]) + 0.5 * byKey[HealthspanSeries.pace]!,
                       accuracy: 1e-9)
        XCTAssertTrue(points.allSatisfy { HealthspanSeries.allKeys.contains($0.key) },
                      "every written key is one a recomputation clears")
    }

    /// Behaviour that never changes ages at exactly 1×.
    func testUnchangingHistoryAgesAtOneTimes() throws {
        let h = history(days: 220) { i, h in h.zones[i] = (15, 1); h.sriAgreement[i] = 0.85 }
        let points = IntelligenceEngine.healthspanPoints(history: h, endDay: today, dayKey: "2026-09-23",
                                                         age: 40, sex: "male", profileWeightKg: 80)
        let pace = try XCTUnwrap(points.first { $0.key == HealthspanSeries.pace }).value
        XCTAssertEqual(pace, 1, accuracy: 1e-9)
    }

    /// A range of days yields one point set per unlocked day, keyed by the right calendar day.
    func testRangeKeysEachDay() {
        let h = history(days: 40)
        let points = IntelligenceEngine.healthspanPoints(history: h, fromDay: today - 2, toDay: today,
                                                         age: 40, sex: "male", profileWeightKg: 80)
        XCTAssertEqual(Set(points.filter { $0.key == HealthspanSeries.bodyAge }.map(\.day)),
                       ["2026-09-21", "2026-09-22", "2026-09-23"])
    }

    /// The day-key helpers are inverses across month and leap boundaries.
    func testDayKeysRoundTrip() {
        let fmt = IntelligenceEngine.healthspanDayFormatter()
        for key in ["2024-02-29", "2024-03-01", "2026-09-01", "2026-12-31"] {
            XCTAssertEqual(IntelligenceEngine.healthspanDayKey(PaceOfAgingEngine.dayIndex(key)!, fmt), key)
        }
    }

    /// The HRR zone pair from the store: a day with either series is observed.
    func testZonesFromStoredSeries() {
        let z = IntelligenceEngine.healthspanZones(
            moderate: [MetricPoint(day: "2026-09-01", key: HealthspanSeries.zoneModerate, value: 30)],
            vigorous: [MetricPoint(day: "2026-09-01", key: HealthspanSeries.zoneVigorous, value: 4),
                       MetricPoint(day: "2026-09-02", key: HealthspanSeries.zoneVigorous, value: 6)])
        XCTAssertEqual(z[PaceOfAgingEngine.dayIndex("2026-09-01")!]?.moderate, 30)
        XCTAssertEqual(z[PaceOfAgingEngine.dayIndex("2026-09-01")!]?.vigorous, 4)
        XCTAssertEqual(z[PaceOfAgingEngine.dayIndex("2026-09-02")!]?.moderate, 0)
    }
}
