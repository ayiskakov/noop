import XCTest
@testable import Strand
import StrandAnalytics
import WhoopStore

/// The orchestration half of Healthspan: how the analytics pass turns stored days and activity series into
/// `VitalityEngine.Inputs`, and how it lays those out as one rolling sample per day for the pace fit.
///
/// The engines themselves are covered in the StrandAnalytics package, against a committed oracle. What is
/// only testable here is the ASSEMBLY: which days count as observed, how a partial week is scaled to a
/// weekly dose, and which windows are allowed to become a sample at all.
///
/// `@MainActor`: the helpers are main-actor-isolated on `IntelligenceEngine`, so the fixture runs there.
@MainActor
final class HealthspanInputsTests: XCTestCase {

    /// A day carrying enough for every non-activity driver, so the assembly under test is the only variable.
    private func day(_ key: String) -> DailyMetric {
        DailyMetric(day: key, totalSleepMin: 450, efficiency: nil, deepMin: nil, remMin: nil,
                    lightMin: nil, disturbances: nil, restingHr: 60, avgHrv: 40, recovery: nil,
                    strain: nil, exerciseCount: nil, steps: 8000)
    }

    /// `count` consecutive calendar days starting at `start`, oldest first.
    private func consecutiveDayKeys(from start: String, count: Int) -> [String] {
        (0..<count).map { IntelligenceEngine.dayKey(daysBefore: -$0, before: start) }
    }

    // MARK: - Weekly dose assembly

    /// Five observed days of 20 moderate minutes is 100 minutes seen and a 140-minute WEEK: the doses are
    /// stated per week whatever coverage the week had, the same treatment the sleep and step means get.
    func testPartialWeekScalesToASevenDayDose() throws {
        let keys = consecutiveDayKeys(from: "2026-09-01", count: 5)
        let zone = Dictionary(uniqueKeysWithValues: keys.map { ($0, (moderate: 20.0, vigorous: 5.0)) })
        let inputs = IntelligenceEngine.healthspanInputs(
            days: keys.map(day), zone: zone, strength: [:], age: 40, sex: "male",
            weightKg: 80, leanMassKg: nil)
        XCTAssertEqual(try XCTUnwrap(inputs.moderateMinPerWeek), 140, accuracy: 1e-9)
        XCTAssertEqual(try XCTUnwrap(inputs.vigorousMinPerWeek), 35, accuracy: 1e-9)
    }

    /// Below the coverage floor there is no dose at all. One logged day is not a week, and multiplying it
    /// by seven would be an invention rather than a measurement.
    func testTooFewObservedDaysYieldsNoDose() {
        let keys = consecutiveDayKeys(from: "2026-09-01", count: 3)
        let zone = Dictionary(uniqueKeysWithValues: keys.map { ($0, (moderate: 60.0, vigorous: 30.0)) })
        let inputs = IntelligenceEngine.healthspanInputs(
            days: keys.map(day), zone: zone, strength: [keys[0]: 45], age: 40, sex: "male",
            weightKg: 80, leanMassKg: nil)
        XCTAssertNil(inputs.moderateMinPerWeek)
        XCTAssertNil(inputs.vigorousMinPerWeek)
        XCTAssertNil(inputs.strengthMinPerWeek)
        // The non-activity drivers are unaffected: a thin activity week still has a resting HR.
        XCTAssertNotNil(inputs.restingHR)
    }

    /// A day we WATCHED with no strength entry did no strength training — zero, not unknown. Only a day the
    /// strap actually saw can tell those apart, which is why observation is keyed on the zone reading.
    func testAWatchedDayWithNoStrengthCountsAsZero() throws {
        let keys = consecutiveDayKeys(from: "2026-09-01", count: 7)
        let zone = Dictionary(uniqueKeysWithValues: keys.map { ($0, (moderate: 10.0, vigorous: 0.0)) })
        let inputs = IntelligenceEngine.healthspanInputs(
            days: keys.map(day), zone: zone, strength: [keys[2]: 35], age: 40, sex: "male",
            weightKg: 80, leanMassKg: nil)
        // 35 minutes across seven observed days, scaled to a seven-day week, is still 35.
        XCTAssertEqual(try XCTUnwrap(inputs.strengthMinPerWeek), 35, accuracy: 1e-9)
    }

    /// Days the strap never saw are not counted as sedentary: an unobserved day is absent from the dose,
    /// not a zero dragging it down.
    func testUnobservedDaysAreNotTreatedAsZero() throws {
        let keys = consecutiveDayKeys(from: "2026-09-01", count: 7)
        let zone = Dictionary(uniqueKeysWithValues: keys.prefix(4).map { ($0, (moderate: 30.0, vigorous: 0.0)) })
        let inputs = IntelligenceEngine.healthspanInputs(
            days: keys.map(day), zone: zone, strength: [:], age: 40, sex: "male",
            weightKg: 80, leanMassKg: nil)
        // 120 minutes over 4 observed days is 30/day, so a 210-minute week — not the 120 actually seen.
        XCTAssertEqual(try XCTUnwrap(inputs.moderateMinPerWeek), 210, accuracy: 1e-9)
    }

    /// Lean mass needs both halves of the percentage; a mass with no weight contributes nothing rather
    /// than a wrong one.
    func testLeanMassNeedsWeightAndMass() {
        let keys = consecutiveDayKeys(from: "2026-09-01", count: 7)
        let withBoth = IntelligenceEngine.healthspanInputs(
            days: keys.map(day), zone: [:], strength: [:], age: 40, sex: "male",
            weightKg: 80, leanMassKg: 60)
        XCTAssertNotNil(VitalityEngine.contributions(withBoth).first { $0.key == "leanmass" })
        let noWeight = IntelligenceEngine.healthspanInputs(
            days: keys.map(day), zone: [:], strength: [:], age: 40, sex: "male",
            weightKg: nil, leanMassKg: 60)
        XCTAssertNil(VitalityEngine.contributions(noWeight).first { $0.key == "leanmass" })
    }

    // MARK: - Rolling samples for the pace fit

    /// One sample per day across the trend window, each carrying the factor signature behind it, on a real
    /// time base the fit can use.
    func testRollingSamplesSpanTheTrendWindow() {
        let keys = consecutiveDayKeys(from: "2026-03-01", count: 200)
        let samples = IntelligenceEngine.healthspanPaceSamples(
            days: keys.map(day), zone: [:], strength: [:], age: 40, sex: "male",
            weightKg: 80, leanMassKg: nil)
        XCTAssertEqual(samples.count, PaceOfAgingEngine.trendWindowDays)
        XCTAssertEqual(Set(samples.map { $0.factorSignature }).count, 1,
                       "an unchanging history must produce one signature, or the fit drops its own samples")
        XCTAssertEqual(samples.map { $0.dayIndex }, samples.map { $0.dayIndex }.sorted())
        XCTAssertEqual(Set(samples.map { $0.dayIndex }).count, samples.count)
        // Behaviour that never changes is a flat series, which is what the engine reads as 1×.
        XCTAssertEqual(Set(samples.map { $0.lnHazardSum }).count, 1)
        XCTAssertEqual(try XCTUnwrap(PaceOfAgingEngine.compute(samples: samples)).pace, 1.0, accuracy: 1e-9)
    }

    /// The ragged start of someone's history is not fitted as a trend: a window holding fewer than
    /// `minWindowDays` real days never becomes a sample.
    func testThinWindowsAreNotSampled() {
        let keys = consecutiveDayKeys(from: "2026-08-01", count: 40)
        let samples = IntelligenceEngine.healthspanPaceSamples(
            days: keys.map(day), zone: [:], strength: [:], age: 40, sex: "male",
            weightKg: 80, leanMassKg: nil)
        XCTAssertEqual(samples.count, 40 - PaceOfAgingEngine.minWindowDays + 1)
        XCTAssertNil(PaceOfAgingEngine.compute(samples: samples),
                     "26 samples is below the pace engine's own floor, so no pace is reported")
    }

    func testNoHistoryYieldsNoSamples() {
        XCTAssertTrue(IntelligenceEngine.healthspanPaceSamples(
            days: [], zone: [:], strength: [:], age: 40, sex: "male",
            weightKg: 80, leanMassKg: nil).isEmpty)
    }

    /// `dayKey` walks the calendar both ways and lands on real dates across a month boundary.
    func testDayKeyWalksTheCalendar() {
        XCTAssertEqual(IntelligenceEngine.dayKey(daysBefore: 1, before: "2026-09-01"), "2026-08-31")
        XCTAssertEqual(IntelligenceEngine.dayKey(daysBefore: -1, before: "2026-08-31"), "2026-09-01")
        XCTAssertEqual(IntelligenceEngine.dayKey(daysBefore: 0, before: "2026-09-22"), "2026-09-22")
        XCTAssertEqual(IntelligenceEngine.dayKey(daysBefore: 1, before: "2024-03-01"), "2024-02-29")
    }
}
