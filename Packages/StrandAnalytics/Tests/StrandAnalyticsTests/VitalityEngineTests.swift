import XCTest
@testable import StrandAnalytics

/// Behavioural properties of the v2 Body Age model. The exact numbers are pinned by `HealthspanOracleTests`;
/// these name the properties those numbers must have.
///
/// Changed from v1, deliberately: the "average person reads at their age" tests became "a person meeting
/// every TARGET reads at their age" (the referent moved to WHOOP's anchor); the HRV tests were dropped (HRV
/// is context, not a driver); the fat-free-mass-index tests became lean-mass-percentage tests; and the
/// aerobic tests now anchor on the heart-rate-reserve zone targets instead of the 150 / 75 self-report
/// guideline.
final class VitalityEngineTests: XCTestCase {

    private func atTargets(age: Double = 30, sex: String = "male") -> VitalityEngine.Inputs {
        .init(chronoAge: age, sex: sex,
              restingHR: VitalityEngine.restingHRTarget(sex: sex),
              vo2max: VitalityEngine.vo2maxTarget(age: age, sex: sex),
              sleepHours: 8, sleepRegularity: VitalityEngine.sriTarget,
              steps: VitalityEngine.stepsTarget(age: age),
              moderateMinPerWeek: VitalityEngine.moderateTarget(age: age),
              vigorousMinPerWeek: VitalityEngine.vigorousTarget(age: age),
              strengthMinPerWeek: VitalityEngine.strengthTargetMinPerWeek,
              leanMassKg: VitalityEngine.leanMassTarget(age: age, sex: sex), weightKg: 100)
    }

    /// Meeting every target reads exactly your age, at every age and for both sexes — the referent.
    func testMeetingEveryTargetReadsAtYourAge() {
        for age in [18.0, 30, 45, 60, 75] {
            for sex in ["male", "female"] {
                let r = VitalityEngine.compute(atTargets(age: age, sex: sex))!
                XCTAssertEqual(r.bodyAge, age, accuracy: 1e-9, "\(sex) \(age)")
                XCTAssertEqual(r.vitality, 50, accuracy: 1e-9)
                XCTAssertEqual(r.factorsUsed, 9)
                XCTAssertNil(r.biggestLever, "nothing to gain when every target is met")
            }
        }
    }

    /// Years are 10 · ln(HR) (Spiegelhalter), so a single unshrunk driver's share is exactly that.
    func testYearsAreTenTimesLnHazard() {
        XCTAssertEqual(VitalityEngine.lnHazardPerYear, 0.1)
        let r = VitalityEngine.compute(.init(chronoAge: 40, restingHR: 70, sleepHours: 8,
                                             leanMassKg: 80, weightKg: 100))!
        let rhr = r.contributions.first { $0.key == "rhr" }!
        XCTAssertEqual(rhr.deltaYears!, 10 * rhr.lnHazard * VitalityEngine.overlapShrink, accuracy: 1e-12)
    }

    func testNilBelowMinFactors() {
        XCTAssertNil(VitalityEngine.compute(.init(chronoAge: 40, restingHR: 65, sleepHours: 7.5)))
        XCTAssertNotNil(VitalityEngine.compute(.init(chronoAge: 40, restingHR: 65, sleepHours: 7.5,
                                                     sleepRegularity: 70)))
        XCTAssertNil(VitalityEngine.compute(.init(chronoAge: 0, restingHR: 65, sleepHours: 7.5,
                                                  sleepRegularity: 70)))
    }

    func testClamps() {
        let r = VitalityEngine.compute(.init(chronoAge: 95, sex: "female", restingHR: 110, vo2max: 8,
                                             sleepHours: 3, sleepRegularity: -50, steps: 0))!
        XCTAssertLessThanOrEqual(r.bodyAge, VitalityEngine.maxBodyAge)
        XCTAssertGreaterThanOrEqual(r.vitality, 0)
    }

    /// The breakdown must reconcile with the headline it explains: per-factor shares sum to the offset.
    func testSharesSumToTheBodyAgeOffset() {
        let r = VitalityEngine.compute(.init(
            chronoAge: 40, sex: "male", restingHR: 72, vo2max: 38, sleepHours: 6.2, sleepRegularity: 58,
            steps: 4200, moderateMinPerWeek: 60, vigorousMinPerWeek: 4, strengthMinPerWeek: 0,
            leanMassKg: 58, weightKg: 84))!
        let summed = r.contributions.reduce(0) { $0 + ($1.deltaYears ?? 0) }
        XCTAssertEqual(summed, r.bodyAge - r.chronoAge, accuracy: 1e-9)
        XCTAssertEqual(r.unclampedBodyAge, r.bodyAge, accuracy: 1e-9)
    }

    /// The biggest lever is the driver costing the most years, and reaching its target removes exactly
    /// its share — the claim the tab makes ("would take ~X years off").
    func testBiggestLeverIsExactlyWhatItsTargetRemoves() {
        var i = VitalityEngine.Inputs(chronoAge: 40, sex: "male", restingHR: 62, sleepHours: 7.5,
                                      sleepRegularity: 72, steps: 8500, strengthMinPerWeek: 0)
        let before = VitalityEngine.compute(i)!
        let lever = before.biggestLever!
        XCTAssertEqual(lever.key, "strength")
        i.strengthMinPerWeek = VitalityEngine.strengthTargetMinPerWeek
        let after = VitalityEngine.compute(i)!
        XCTAssertEqual(before.bodyAge - after.bodyAge, lever.deltaYears!, accuracy: 1e-9)
    }

    // MARK: - Curves

    /// Every curve is zero at its target (the referent), for both sexes and across ages.
    func testEveryCurveIsZeroAtItsTarget() {
        for age in [20.0, 40, 65, 80] {
            for sex in ["male", "female"] {
                XCTAssertEqual(VitalityEngine.restingHRLnHazard(bpm: VitalityEngine.restingHRTarget(sex: sex), sex: sex), 0, accuracy: 1e-12)
                let t = VitalityEngine.vo2maxTarget(age: age, sex: sex)
                XCTAssertEqual(VitalityEngine.vo2maxLnHazard(vo2max: t, target: t), 0, accuracy: 1e-12)
                XCTAssertEqual(VitalityEngine.leanMassLnHazard(
                    percent: VitalityEngine.leanMassTarget(age: age, sex: sex), age: age, sex: sex), 0, accuracy: 1e-12)
            }
            XCTAssertEqual(VitalityEngine.moderateLnHazard(minPerWeek: VitalityEngine.moderateTarget(age: age), age: age), 0, accuracy: 1e-12)
            XCTAssertEqual(VitalityEngine.vigorousLnHazard(minPerWeek: VitalityEngine.vigorousTarget(age: age), age: age), 0, accuracy: 1e-12)
            XCTAssertEqual(VitalityEngine.stepsLnHazard(steps: VitalityEngine.stepsTarget(age: age), age: age), 0, accuracy: 1e-12)
        }
        XCTAssertEqual(VitalityEngine.sriLnHazard(sri: 70), 0, accuracy: 1e-12)
        XCTAssertEqual(VitalityEngine.strengthLnHazard(minPerWeek: 40), 0, accuracy: 1e-12)
        for h in [7.0, 8, 9] { XCTAssertEqual(VitalityEngine.sleepDurationLnHazard(hours: h), 0) }
    }

    /// Short sleep costs more per hour than long sleep (device evidence), and neither grows past 3 h.
    func testSleepDurationIsAsymmetric() {
        let short = VitalityEngine.sleepDurationLnHazard(hours: 6)
        let long = VitalityEngine.sleepDurationLnHazard(hours: 10)
        XCTAssertEqual(short, log(1.27), accuracy: 1e-12)
        XCTAssertEqual(long, log(1.16), accuracy: 1e-12)
        XCTAssertGreaterThan(short, long)
        XCTAssertEqual(VitalityEngine.sleepDurationLnHazard(hours: 2),
                       VitalityEngine.sleepDurationLnHazard(hours: 4), accuracy: 1e-12)
    }

    /// Regularity is a hinge: most of the hazard sits in the least-regular range, the curve is flat above
    /// the median, and it never extrapolates below the lowest quintile's level.
    func testRegularityIsAHinge() {
        let drop55to70 = VitalityEngine.sriLnHazard(sri: 55) - VitalityEngine.sriLnHazard(sri: 70)
        let drop70to85 = VitalityEngine.sriLnHazard(sri: 70) - VitalityEngine.sriLnHazard(sri: 85)
        XCTAssertGreaterThan(drop55to70, drop70to85)
        XCTAssertEqual(VitalityEngine.sriLnHazard(sri: 81), VitalityEngine.sriLnHazard(sri: 100), accuracy: 1e-12)
        XCTAssertEqual(VitalityEngine.sriLnHazard(sri: 55), VitalityEngine.sriLnHazard(sri: -40), accuracy: 1e-12)
    }

    /// With regularity scored, duration counts at half weight — one habit is not counted twice.
    func testDurationIsDownWeightedWhenRegularityIsPresent() {
        let with = VitalityEngine.contributions(.init(chronoAge: 40, sleepHours: 6, sleepRegularity: 70))
        let without = VitalityEngine.contributions(.init(chronoAge: 40, sleepHours: 6))
        XCTAssertEqual(with.first { $0.key == "sleep" }!.lnHazard,
                       without.first { $0.key == "sleep" }!.lnHazard * VitalityEngine.durationWeightWithRegularity,
                       accuracy: 1e-12)
    }

    /// The zone targets are the device-scale ones (7–10 and 70–100 min/wk), and they ease with age.
    func testZoneTargetsAreDeviceScaleAndAgeDeclining() {
        XCTAssertEqual(VitalityEngine.moderateTarget(age: 30), 100)
        XCTAssertEqual(VitalityEngine.moderateTarget(age: 70), 70)
        XCTAssertEqual(VitalityEngine.vigorousTarget(age: 25), 10)
        XCTAssertEqual(VitalityEngine.vigorousTarget(age: 80), 7)
        // Ahmadi's anchors: 15 and 54 min/wk versus none.
        let none = VitalityEngine.vigorousLnHazard(minPerWeek: 0, age: 30)
        XCTAssertEqual(VitalityEngine.vigorousLnHazard(minPerWeek: 15, age: 30) - none, log(0.82), accuracy: 1e-12)
        XCTAssertEqual(VitalityEngine.vigorousLnHazard(minPerWeek: 54, age: 30) - none, log(0.64), accuracy: 1e-12)
        XCTAssertEqual(VitalityEngine.vigorousLnHazard(minPerWeek: 54, age: 30),
                       VitalityEngine.vigorousLnHazard(minPerWeek: 500, age: 30), accuracy: 1e-12)
        // Moderate flattens at three times its target.
        XCTAssertEqual(VitalityEngine.moderateLnHazard(minPerWeek: 300, age: 30),
                       VitalityEngine.moderateLnHazard(minPerWeek: 3000, age: 30), accuracy: 1e-12)
        XCTAssertEqual(VitalityEngine.moderateLnHazard(minPerWeek: -40, age: 30),
                       VitalityEngine.moderateLnHazard(minPerWeek: 0, age: 30), accuracy: 1e-12)
    }

    /// Strength is benefit-only: nothing above the target, and never a penalty for volume.
    func testStrengthPlateausAndNeverPenalisesVolume() {
        XCTAssertEqual(VitalityEngine.strengthLnHazard(minPerWeek: 0), -log(0.90), accuracy: 1e-12)
        for minutes in [40.0, 90, 120, 400, 10_000] {
            XCTAssertEqual(VitalityEngine.strengthLnHazard(minPerWeek: minutes), 0, accuracy: 1e-12)
        }
    }

    /// Steps: 5,600 is the target from 60, and the curve does not extrapolate below ~3.5k.
    func testStepsTargetDropsAtSixty() {
        XCTAssertEqual(VitalityEngine.stepsTarget(age: 59), 8000)
        XCTAssertEqual(VitalityEngine.stepsTarget(age: 60), 5600)
        XCTAssertEqual(VitalityEngine.stepsLnHazard(steps: 1000, age: 40),
                       VitalityEngine.stepsLnHazard(steps: 3000, age: 40), accuracy: 1e-12)
        XCTAssertGreaterThan(VitalityEngine.stepsLnHazard(steps: 5000, age: 40),
                             VitalityEngine.stepsLnHazard(steps: 5000, age: 65))
    }

    /// Lean mass only penalises below target, is capped, and softens the whole result's claim.
    func testLeanMassIsPenaltyOnlyAndLowersConfidence() {
        XCTAssertEqual(VitalityEngine.leanMassLnHazard(percent: 95, age: 30, sex: "male"), 0)
        XCTAssertEqual(VitalityEngine.leanMassLnHazard(percent: 70, age: 30, sex: "male"), log(1.31), accuracy: 1e-12)
        XCTAssertEqual(VitalityEngine.leanMassLnHazard(percent: 40, age: 30, sex: "male"), log(1.31), accuracy: 1e-12)
        XCTAssertEqual(VitalityEngine.leanMassTarget(age: 30, sex: "female"), 67)
        XCTAssertEqual(VitalityEngine.leanMassTarget(age: 50, sex: "male"), 78, accuracy: 1e-12)
        XCTAssertNil(VitalityEngine.leanMassPercent(leanMassKg: 60, weightKg: 0))
        let withLean = VitalityEngine.compute(.init(chronoAge: 40, restingHR: 65, sleepHours: 7.5,
                                                    leanMassKg: 60, weightKg: 80))!
        XCTAssertTrue(withLean.lowerConfidence)
        let without = VitalityEngine.compute(.init(chronoAge: 40, restingHR: 65, sleepHours: 7.5, steps: 7000))!
        XCTAssertFalse(without.lowerConfidence)
        // Needs both halves of the ratio.
        XCTAssertFalse(VitalityEngine.contributions(.init(chronoAge: 40, leanMassKg: 60)).contains { $0.key == "leanmass" })
    }

    // MARK: - Overlap

    /// Four activity drivers are four views of one behaviour: the shared driver's share halves (√4).
    func testActivityDriversDoNotCompound() {
        let one = VitalityEngine.compute(.init(chronoAge: 40, restingHR: 60, sleepHours: 8, steps: 3000))!
        let four = VitalityEngine.compute(.init(chronoAge: 40, restingHR: 60, sleepHours: 8, steps: 3000,
                                                moderateMinPerWeek: 0, vigorousMinPerWeek: 0,
                                                strengthMinPerWeek: 0))!
        let stepsAlone = one.contributions.first { $0.key == "steps" }!.deltaYears!
        let stepsShared = four.contributions.first { $0.key == "steps" }!.deltaYears!
        XCTAssertEqual(stepsShared, stepsAlone / 2, accuracy: 1e-12)
    }

    /// A strap-derived VO₂max is mostly resting HR read twice, so the two fold into their mean; an
    /// external VO₂max is an independent reading and keeps √n.
    func testStrapVO2maxFoldsIntoRestingHR() {
        var i = VitalityEngine.Inputs(chronoAge: 40, sex: "male", restingHR: 70, vo2max: 36,
                                      sleepHours: 8, steps: 8000)
        let strap = VitalityEngine.compute(i)!
        i.vo2maxSource = .external
        let external = VitalityEngine.compute(i)!
        let rhrStrap = strap.contributions.first { $0.key == "rhr" }!
        let rhrExternal = external.contributions.first { $0.key == "rhr" }!
        XCTAssertEqual(rhrStrap.deltaYears!, rhrStrap.lnHazard / 2 * VitalityEngine.overlapShrink * 10, accuracy: 1e-12)
        XCTAssertEqual(rhrExternal.deltaYears!, rhrExternal.lnHazard / 2.0.squareRoot() * VitalityEngine.overlapShrink * 10, accuracy: 1e-12)
        XCTAssertGreaterThan(external.bodyAge, strap.bodyAge, "an independent reading counts for more")
    }

    /// Unlock: 21 scored days in the last 31, and an adult.
    func testUnlockGate() {
        XCTAssertEqual(VitalityEngine.unlockStatus(scoredDaysInWindow: 20, age: 40).unlocked, false)
        XCTAssertEqual(VitalityEngine.unlockStatus(scoredDaysInWindow: 20, age: 40).daysUntilUnlock, 1)
        XCTAssertEqual(VitalityEngine.unlockStatus(scoredDaysInWindow: 21, age: 40).unlocked, true)
        XCTAssertEqual(VitalityEngine.unlockStatus(scoredDaysInWindow: 31, age: 17).unlocked, false)
        XCTAssertEqual(VitalityEngine.unlockStatus(scoredDaysInWindow: 0, age: 40).daysUntilUnlock, 21)
    }

    /// Restricting inputs to a key set removes exactly the other drivers.
    func testRestrictedKeepsOnlyTheNamedDrivers() {
        let all = atTargets()
        let keys: Set<String> = ["rhr", "steps", "consistency"]
        XCTAssertEqual(Set(VitalityEngine.contributions(all.restricted(to: keys)).map(\.key)), keys)
    }

    func testRmssdNormByAge() {
        XCTAssertEqual(VitalityEngine.rmssdNorm(forAge: 20), 47, accuracy: 0.01)
        XCTAssertEqual(VitalityEngine.rmssdNorm(forAge: 45), 31, accuracy: 0.01)
        XCTAssertEqual(VitalityEngine.rmssdNorm(forAge: 90), 20, accuracy: 0.01)
    }

    /// The duration-CV helper stays for the Rest score's consistency term (it no longer feeds Body Age).
    func testSleepConsistency() {
        XCTAssertEqual(VitalityEngine.sleepConsistency(nightlyHours: [7, 7, 7, 7])!, 1.0, accuracy: 1e-9)
        XCTAssertEqual(VitalityEngine.sleepConsistency(nightlyHours: [6, 8, 6, 8])!, 0.857, accuracy: 0.005)
        XCTAssertNil(VitalityEngine.sleepConsistency(nightlyHours: [7, 7]))
    }
}
