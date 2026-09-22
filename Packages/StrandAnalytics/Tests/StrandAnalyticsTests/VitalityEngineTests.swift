import XCTest
@testable import StrandAnalytics

final class VitalityEngineTests: XCTestCase {

    /// An average-for-their-age person nets ~0 hazard → Body Age == chronological age, Vitality 50.
    func testAveragePersonReadsAtTheirAge() {
        let r = VitalityEngine.compute(.init(
            chronoAge: 40, restingHR: 65, vo2max: 45, expectedVO2max: 45,
            sleepHours: 7.5, sleepConsistency: 0.75, rmssd: 45, rmssdNorm: 45, steps: 7000))!
        XCTAssertEqual(r.bodyAge, 40, accuracy: 0.01)
        XCTAssertEqual(r.vitality, 50, accuracy: 0.01)
        XCTAssertEqual(r.deltaYears, 0, accuracy: 0.01)
        XCTAssertEqual(r.factorsUsed, 6)
    }

    /// The same invariant with EVERY driver present: a person sitting exactly on all ten references still
    /// reads at their own age. This is what makes the references a coherent set rather than ten separately
    /// plausible numbers — adding a driver must not move an average person off their own age.
    func testAveragePersonReadsAtTheirAgeWithEveryDriver() {
        let r = VitalityEngine.compute(.init(
            chronoAge: 40, restingHR: 65, vo2max: 45, expectedVO2max: 45,
            sleepHours: 7.5, sleepConsistency: 0.75, rmssd: 45, rmssdNorm: 45, steps: 7000,
            moderateMinPerWeek: VitalityEngine.moderateTargetMinPerWeek,
            vigorousMinPerWeek: VitalityEngine.vigorousTargetMinPerWeek,
            strengthMinPerWeek: VitalityEngine.strengthTargetMinPerWeek,
            leanMassKg: 60, heightCm: 180, sex: "male"))!
        XCTAssertEqual(r.bodyAge, 40, accuracy: 0.01)
        XCTAssertEqual(r.deltaYears, 0, accuracy: 0.01)
        XCTAssertEqual(r.factorsUsed, 10)
        XCTAssertTrue(r.lowerConfidence, "the fat-free-mass factor softens the claim whenever it is used")
    }

    /// A clearly healthy person reads younger + higher vitality (oracle Δage ≈ −6.09).
    func testHealthyPersonIsYounger() {
        let r = VitalityEngine.compute(.init(
            chronoAge: 40, restingHR: 52, vo2max: 55.5, expectedVO2max: 45,
            sleepHours: 7.5, sleepConsistency: 0.9, rmssd: 54, rmssdNorm: 45, steps: 11000))!
        XCTAssertEqual(r.bodyAge, 33.911, accuracy: 0.01)
        XCTAssertEqual(r.vitality, 65.222, accuracy: 0.01)
        XCTAssertGreaterThan(r.deltaYears, 0)   // younger than chrono age
    }

    /// A clearly unhealthy person reads older + lower vitality (oracle Δage ≈ +7.64).
    func testUnhealthyPersonIsOlder() {
        let r = VitalityEngine.compute(.init(
            chronoAge: 40, restingHR: 80, vo2max: 34.5, expectedVO2max: 45,
            sleepHours: 5.5, sleepConsistency: 0.5, rmssd: 31.5, rmssdNorm: 45, steps: 3000))!
        XCTAssertEqual(r.bodyAge, 47.635, accuracy: 0.01)
        XCTAssertEqual(r.vitality, 30.912, accuracy: 0.01)
        XCTAssertLessThan(r.deltaYears, 0)      // older than chrono age
    }

    /// Below the minimum-factor honesty gate → nil (don't show a number on too little data).
    func testNilBelowMinFactors() {
        XCTAssertNil(VitalityEngine.compute(.init(chronoAge: 40, restingHR: 65, sleepHours: 7.5))) // 2 factors
        XCTAssertNotNil(VitalityEngine.compute(.init(chronoAge: 40, restingHR: 65, sleepHours: 7.5,
                                                     sleepConsistency: 0.75)))                     // 3 factors
    }

    /// Body Age + Vitality stay within their clamped ranges at the extremes.
    func testClamps() {
        let young = VitalityEngine.compute(.init(
            chronoAge: 22, restingHR: 40, vo2max: 70, expectedVO2max: 40,
            sleepHours: 7.5, sleepConsistency: 1.0, rmssd: 90, rmssdNorm: 45, steps: 11000))!
        XCTAssertGreaterThanOrEqual(young.bodyAge, VitalityEngine.minBodyAge)
        XCTAssertLessThanOrEqual(young.vitality, 100)
        XCTAssertGreaterThanOrEqual(young.vitality, 0)

        let old = VitalityEngine.compute(.init(
            chronoAge: 85, restingHR: 110, vo2max: 12, expectedVO2max: 35,
            sleepHours: 3, sleepConsistency: 0.1, rmssd: 8, rmssdNorm: 30, steps: 200))!
        XCTAssertLessThanOrEqual(old.bodyAge, VitalityEngine.maxBodyAge)
        XCTAssertGreaterThanOrEqual(old.vitality, 0)
    }

    func testRmssdNormByAge() {
        XCTAssertEqual(VitalityEngine.rmssdNorm(forAge: 20), 47, accuracy: 0.01)
        XCTAssertEqual(VitalityEngine.rmssdNorm(forAge: 40), 33, accuracy: 0.01)
        XCTAssertEqual(VitalityEngine.rmssdNorm(forAge: 45), 31, accuracy: 0.01)   // halfway 33→29
        XCTAssertEqual(VitalityEngine.rmssdNorm(forAge: 90), 20, accuracy: 0.01)   // clamps to last anchor
    }

    func testSleepConsistency() {
        XCTAssertEqual(VitalityEngine.sleepConsistency(nightlyHours: [7, 7, 7, 7])!, 1.0, accuracy: 1e-9)
        XCTAssertEqual(VitalityEngine.sleepConsistency(nightlyHours: [6, 8, 6, 8])!, 0.857, accuracy: 0.005)
        XCTAssertNil(VitalityEngine.sleepConsistency(nightlyHours: [7, 7]))   // < 3 nights
    }

    /// Contributions carry the right sign: a low resting HR is protective (negative), a high one ages you.
    func testContributionSigns() {
        let lowRHR = VitalityEngine.contributions(.init(chronoAge: 40, restingHR: 50))
            .first { $0.key == "rhr" }!
        XCTAssertLessThan(lowRHR.lnHazard, 0)
        let highRHR = VitalityEngine.contributions(.init(chronoAge: 40, restingHR: 85))
            .first { $0.key == "rhr" }!
        XCTAssertGreaterThan(highRHR.lnHazard, 0)
    }

    // MARK: - Domain grouping

    /// THE regression this grouping exists for. A sedentary person scored on all four activity drivers
    /// must not be charged roughly four times what one driver charges: they are four readings of one
    /// behaviour, not four independent failures. Oracle: +2.216 yr on steps alone, +3.388 yr on all four.
    func testActivityDriversDoNotCompound() {
        let one = VitalityEngine.compute(.init(
            chronoAge: 40, restingHR: 65, sleepHours: 7.5, sleepConsistency: 0.75, steps: 0))!
        let four = VitalityEngine.compute(.init(
            chronoAge: 40, restingHR: 65, sleepHours: 7.5, sleepConsistency: 0.75, steps: 0,
            moderateMinPerWeek: 0, vigorousMinPerWeek: 0, strengthMinPerWeek: 0))!

        let oneCost = one.bodyAge - one.chronoAge
        let fourCost = four.bodyAge - four.chronoAge
        XCTAssertEqual(oneCost, 2.216, accuracy: 0.01)
        XCTAssertEqual(fourCost, 3.388, accuracy: 0.01)
        XCTAssertLessThan(fourCost, oneCost * 2,
                          "four views of one behaviour must not cost close to four times one view")

        // And the shared driver's own share halves as three siblings join it (√4 = 2).
        let stepsAlone = one.contributions.first { $0.key == "steps" }!.deltaYears!
        let stepsShared = four.contributions.first { $0.key == "steps" }!.deltaYears!
        XCTAssertEqual(stepsShared, stepsAlone / 2, accuracy: 1e-9)
    }

    /// The breakdown must reconcile with the headline it explains: per-factor shares sum to the offset.
    /// A UI that renders `Result.contributions` beside `bodyAge` therefore cannot show two disagreeing
    /// readouts of one fact, because there is only one computation behind both.
    func testSharesSumToTheBodyAgeOffset() {
        let r = VitalityEngine.compute(.init(
            chronoAge: 40, restingHR: 72, vo2max: 38, expectedVO2max: 45,
            sleepHours: 6.2, sleepConsistency: 0.6, rmssd: 30, rmssdNorm: 45, steps: 4200,
            moderateMinPerWeek: 60, vigorousMinPerWeek: 10, strengthMinPerWeek: 0,
            leanMassKg: 52, heightCm: 180, sex: "male"))!
        let summed = r.contributions.reduce(0) { $0 + ($1.deltaYears ?? 0) }
        XCTAssertEqual(summed, r.bodyAge - r.chronoAge, accuracy: 1e-9)
        XCTAssertEqual(summed * VitalityEngine.lnHazardPerYear, r.lnHazardSum, accuracy: 1e-9)
    }

    /// The raw list carries no share — only `compute` knows the domain shrink, so nothing downstream can
    /// mistake an unshrunk log-hazard for a number of years.
    func testRawContributionsCarryNoDeltaYears() {
        for c in VitalityEngine.contributions(.init(chronoAge: 40, restingHR: 70, steps: 5000)) {
            XCTAssertNil(c.deltaYears, c.key)
        }
    }

    // MARK: - The four added drivers

    /// Each aerobic curve is zero at its published guideline, positive below it, and never rewards volume
    /// past the point the cohort stopped showing further benefit.
    func testAerobicCurvesAnchorOnTheGuideline() {
        XCTAssertEqual(VitalityEngine.moderateLnHazard(minPerWeek: 150), 0, accuracy: 1e-9)
        XCTAssertEqual(VitalityEngine.vigorousLnHazard(minPerWeek: 75), 0, accuracy: 1e-9)
        XCTAssertEqual(VitalityEngine.moderateLnHazard(minPerWeek: 0), -log(0.81), accuracy: 1e-9)
        XCTAssertEqual(VitalityEngine.vigorousLnHazard(minPerWeek: 0), -log(0.81), accuracy: 1e-9)
        // Flat beyond the top published category — more volume buys nothing further.
        XCTAssertEqual(VitalityEngine.moderateLnHazard(minPerWeek: 300),
                       VitalityEngine.moderateLnHazard(minPerWeek: 5000), accuracy: 1e-12)
        XCTAssertEqual(VitalityEngine.vigorousLnHazard(minPerWeek: 150),
                       VitalityEngine.vigorousLnHazard(minPerWeek: 5000), accuracy: 1e-12)
        // Negative inputs cannot be worse than zero minutes.
        XCTAssertEqual(VitalityEngine.moderateLnHazard(minPerWeek: -40),
                       VitalityEngine.moderateLnHazard(minPerWeek: 0), accuracy: 1e-12)
    }

    /// Strength plateaus at the published optimum and NEVER penalises a high volume: the J-shape's upper
    /// limb is explicitly unresolved in the source, so inventing a harm there would claim more than the
    /// evidence attributes.
    func testStrengthPlateausAndNeverPenalisesVolume() {
        XCTAssertEqual(VitalityEngine.strengthLnHazard(minPerWeek: 0), -log(0.90), accuracy: 1e-9)
        XCTAssertEqual(VitalityEngine.strengthLnHazard(minPerWeek: 30), 0, accuracy: 1e-9)
        for minutes in [30.0, 60, 140, 400, 10_000] {
            XCTAssertEqual(VitalityEngine.strengthLnHazard(minPerWeek: minutes), 0, accuracy: 1e-12)
        }
    }

    /// Lean mass is binary and one-directional: below the sex-specific cutoff it penalises, above it does
    /// nothing. There is no published finding that extra muscle is protective, so none is extrapolated.
    func testLeanMassOnlyPenalisesBelowTheCutoff() {
        XCTAssertEqual(VitalityEngine.ffmiCutoff(sex: "male"), 17)
        XCTAssertEqual(VitalityEngine.ffmiCutoff(sex: "female"), 15)
        XCTAssertEqual(VitalityEngine.ffmiCutoff(sex: "nonbinary"), 17)   // falls back to the men's value
        XCTAssertEqual(VitalityEngine.ffmiLnHazard(ffmi: 16.9, sex: "male"), log(1.57), accuracy: 1e-9)
        XCTAssertEqual(VitalityEngine.ffmiLnHazard(ffmi: 17.0, sex: "male"), 0, accuracy: 1e-12)
        XCTAssertEqual(VitalityEngine.ffmiLnHazard(ffmi: 30.0, sex: "male"), 0, accuracy: 1e-12)
        XCTAssertEqual(VitalityEngine.ffmi(leanMassKg: 60, heightCm: 180)!, 18.518, accuracy: 0.001)
        XCTAssertNil(VitalityEngine.ffmi(leanMassKg: 60, heightCm: 0))
    }

    /// A lean-mass reading softens the whole result's claim; without one nothing is softened.
    func testLeanMassFlagsLowerConfidence() {
        let withLean = VitalityEngine.compute(.init(
            chronoAge: 40, restingHR: 65, sleepHours: 7.5, sleepConsistency: 0.75,
            leanMassKg: 60, heightCm: 180, sex: "male"))!
        XCTAssertTrue(withLean.lowerConfidence)
        let without = VitalityEngine.compute(.init(
            chronoAge: 40, restingHR: 65, sleepHours: 7.5, sleepConsistency: 0.75, steps: 7000))!
        XCTAssertFalse(without.lowerConfidence)
    }

    /// An incomplete body measurement contributes nothing rather than a wrong index.
    func testLeanMassNeedsBothMeasurements() {
        let keys = VitalityEngine.contributions(.init(
            chronoAge: 40, restingHR: 65, leanMassKg: 60)).map(\.key)
        XCTAssertFalse(keys.contains("leanmass"))
    }
}
