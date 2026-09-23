import XCTest
@testable import StrandAnalytics

/// Pace of Aging as WHOOP defines it: the last 30 days held for six months. Exact values on the edge
/// cases are pinned by `HealthspanOracleTests`; these name the properties. (The v1 least-squares drift
/// fit and its tests were retired with it.)
final class PaceOfAgingEngineTests: XCTestCase {}

extension PaceOfAgingEngineTests {

    /// Day indices are differences on a fixed calendar, so a span is the number of days it really is.
    func testDayIndex() {
        XCTAssertEqual(PaceOfAgingEngine.dayIndex("1970-01-01"), 0)
        XCTAssertEqual(PaceOfAgingEngine.dayIndex("1970-01-02"), 1)
        XCTAssertEqual(PaceOfAgingEngine.dayIndex("2026-09-22")! -
                       PaceOfAgingEngine.dayIndex("2026-09-12")!, 10)
        XCTAssertEqual(PaceOfAgingEngine.dayIndex("2026-03-09")! -
                       PaceOfAgingEngine.dayIndex("2026-03-06")!, 3, "a DST weekend is still three days")
        XCTAssertEqual(PaceOfAgingEngine.dayIndex("2024-03-01")! -
                       PaceOfAgingEngine.dayIndex("2024-02-28")!, 2, "a leap day is a day")
        XCTAssertNil(PaceOfAgingEngine.dayIndex("2026-13-01"))
        XCTAssertNil(PaceOfAgingEngine.dayIndex("not-a-day"))
        XCTAssertNil(PaceOfAgingEngine.dayIndex("2026-09"))
    }
}

// MARK: - Projection (WHOOP's definition)

extension PaceOfAgingEngineTests {

    private var person: VitalityEngine.Inputs {
        .init(chronoAge: 35, sex: "male", restingHR: 64, sleepHours: 7.2, sleepRegularity: 66,
              steps: 6500, moderateMinPerWeek: 70, vigorousMinPerWeek: 6, strengthMinPerWeek: 20)
    }

    /// A last month that looks like the last six ages at exactly 1×, and the projection is +6 months.
    func testSteadyHabitsProjectOneTimes() {
        let p = PaceOfAgingEngine.project(baseline: person, recent: person)!
        XCTAssertEqual(p.pace, 1, accuracy: 1e-12)
        XCTAssertEqual(p.projectedBodyAge - p.currentBodyAge, 0.5, accuracy: 1e-12)
        XCTAssertTrue(p.isSteady)
        XCTAssertTrue(p.lowerConfidence, "no monthly windows → the margin is the prior")
    }

    /// pace = 1 + (Δrecent − Δbaseline) / 0.5 y, and the projection moves with the pace it states.
    func testPaceIsTheProjectedChangeOverSixMonths() {
        var recent = person
        recent.strengthMinPerWeek = 40
        let base = VitalityEngine.compute(person)!, rec = VitalityEngine.compute(recent)!
        let p = PaceOfAgingEngine.project(baseline: person, recent: recent)!
        XCTAssertEqual(p.pace, 1 + (rec.bodyAge - base.bodyAge) / 0.5, accuracy: 1e-12)
        XCTAssertLessThan(p.pace, 1)
        XCTAssertEqual(p.projectedBodyAge, p.currentBodyAge + 0.5 * p.pace, accuracy: 1e-12)
        XCTAssertEqual(p.currentBodyAge, base.bodyAge, accuracy: 1e-12)
    }

    /// A driver present in only one window is dropped from the comparison: connecting a scale is not aging.
    func testADriverInOnlyOneWindowIsNotAging() {
        var recent = person
        recent.leanMassKg = 40; recent.weightKg = 90     // far below target: a big cost, if it counted
        let p = PaceOfAgingEngine.project(baseline: person, recent: recent)!
        XCTAssertEqual(p.pace, 1, accuracy: 1e-12)
        XCTAssertFalse(p.comparedKeys.contains("leanmass"))
    }

    /// The measured spread of the monthly windows sets the margin once three windows exist.
    func testMarginComesFromTheMonthlySpread() {
        let windows = (0..<6).map { k -> VitalityEngine.Inputs in
            var w = person; w.steps = 6500 + (k % 2 == 0 ? 500 : -500); return w
        }
        let deltas = windows.map { VitalityEngine.compute($0)!.unclampedBodyAge }
        let mean = deltas.reduce(0, +) / 6
        let sd = (deltas.reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / 5).squareRoot()
        let p = PaceOfAgingEngine.project(baseline: person, recent: person, monthlyWindows: windows)!
        XCTAssertFalse(p.lowerConfidence)
        XCTAssertEqual(p.paceMargin, 1.96 * max(PaceOfAgingEngine.minWindowSD, sd) / 0.5, accuracy: 1e-12)
        let few = PaceOfAgingEngine.project(baseline: person, recent: person,
                                            monthlyWindows: Array(windows.prefix(2)))!
        XCTAssertTrue(few.lowerConfidence)
        XCTAssertEqual(few.paceMargin, 1.96 * PaceOfAgingEngine.priorWindowSD / 0.5, accuracy: 1e-12)
    }

    /// A real change beyond the margin is not called steady, and the scale clamps both ends.
    func testRealChangeAndClamps() {
        var worse = person
        worse.sleepHours = 5; worse.sleepRegularity = 35; worse.steps = 2500
        worse.moderateMinPerWeek = 0; worse.vigorousMinPerWeek = 0; worse.strengthMinPerWeek = 0
        let p = PaceOfAgingEngine.project(baseline: person, recent: worse)!
        XCTAssertFalse(p.isSteady)
        XCTAssertEqual(p.pace, PaceOfAgingEngine.maxPace)
        XCTAssertEqual(PaceOfAgingEngine.project(baseline: worse, recent: person)!.pace, PaceOfAgingEngine.minPace)
    }

    func testUnscorableWindowsYieldNil() {
        XCTAssertNil(PaceOfAgingEngine.project(baseline: .init(chronoAge: 35, restingHR: 60), recent: person))
        XCTAssertNil(PaceOfAgingEngine.project(
            baseline: .init(chronoAge: 35, restingHR: 60, sleepHours: 7, steps: 8000),
            recent: .init(chronoAge: 35, sleepRegularity: 70, moderateMinPerWeek: 50, strengthMinPerWeek: 40)))
    }
}
