import XCTest
@testable import StrandAnalytics

final class PaceOfAgingEngineTests: XCTestCase {

    private let signature = "hrv,rhr,sleep,steps"

    /// A run of samples whose summed log-hazard drifts by `gompertzYearsPerYear` Gompertz-years each
    /// calendar year — i.e. the drift that should read as a pace of `1 + gompertzYearsPerYear`.
    private func drift(_ gompertzYearsPerYear: Double, days: Int = 90,
                       signature: String? = nil) -> [PaceOfAgingEngine.Sample] {
        (0..<days).map {
            PaceOfAgingEngine.Sample(
                dayIndex: $0,
                lnHazardSum: 0.20 + VitalityEngine.lnHazardPerYear
                    * gompertzYearsPerYear * Double($0) / PaceOfAgingEngine.daysPerYear,
                factorSignature: signature ?? self.signature)
        }
    }

    /// Behaviour that holds steady ages at exactly 1× — the property the whole construct rests on. It is
    /// not a calibrated constant: it falls out of `BodyAge = age + S/k` the moment dS/dt is zero.
    func testSteadyBehaviourAgesAtExactlyOne() {
        let r = PaceOfAgingEngine.compute(samples: drift(0))!
        XCTAssertEqual(r.pace, 1.0, accuracy: 1e-9)
        XCTAssertEqual(r.slopeLnPerYear, 0, accuracy: 1e-12)
        XCTAssertTrue(r.isSteady)
        XCTAssertEqual(r.samplesUsed, 90)
        XCTAssertFalse(r.lowerConfidence)
    }

    /// A hazard drifting up by one Gompertz year per calendar year is two years of Body Age per year.
    func testWorseningAndImprovingScaleThroughGompertz() {
        XCTAssertEqual(PaceOfAgingEngine.compute(samples: drift(1))!.pace, 2.0, accuracy: 1e-9)
        XCTAssertEqual(PaceOfAgingEngine.compute(samples: drift(-0.5))!.pace, 0.5, accuracy: 1e-9)
        XCTAssertEqual(PaceOfAgingEngine.compute(samples: drift(0.25))!.pace, 1.25, accuracy: 1e-9)
    }

    /// The scale is bounded at both ends, so a wild fit still renders on the dial.
    func testPaceClampsToTheScale() {
        XCTAssertEqual(PaceOfAgingEngine.compute(samples: drift(-20))!.pace, PaceOfAgingEngine.minPace)
        XCTAssertEqual(PaceOfAgingEngine.compute(samples: drift(20))!.pace, PaceOfAgingEngine.maxPace)
    }

    /// A slope fitted to noise always has SOME sign. Here the true slope is zero and the residuals are
    /// large, so the verdict must be "holding steady" — otherwise a dial swings on nothing.
    func testNoiseReadsAsSteadyNotAsADirection() {
        let noisy = (0..<90).map {
            PaceOfAgingEngine.Sample(dayIndex: $0,
                                     lnHazardSum: 0.20 + ($0 % 2 == 0 ? 0.05 : -0.05),
                                     factorSignature: signature)
        }
        let r = PaceOfAgingEngine.compute(samples: noisy)!
        XCTAssertTrue(r.isSteady, "a zig-zag around a flat mean is not a direction")
        XCTAssertGreaterThan(r.paceMargin, abs(r.pace - 1),
                             "the band must cover 1× whenever the verdict is steady")
    }

    /// A real trend is NOT called steady — the steadiness guard must not swallow genuine signal.
    func testARealTrendIsNotCalledSteady() {
        XCTAssertFalse(PaceOfAgingEngine.compute(samples: drift(1))!.isSteady)
        XCTAssertFalse(PaceOfAgingEngine.compute(samples: drift(-0.5))!.isSteady)
    }

    /// Below the sample floor there is no number at all, and the countdown says how far off it is.
    func testGatedBelowTheSampleFloor() {
        XCTAssertNil(PaceOfAgingEngine.compute(samples: drift(0, days: 59)))
        XCTAssertEqual(PaceOfAgingEngine.daysUntilReady(drift(0, days: 59)), 1)
        XCTAssertEqual(PaceOfAgingEngine.daysUntilReady(drift(0, days: 40)), 20)
        XCTAssertEqual(PaceOfAgingEngine.daysUntilReady(drift(0, days: 90)), 0)
        XCTAssertNotNil(PaceOfAgingEngine.compute(samples: drift(0, days: 60)))
        XCTAssertTrue(PaceOfAgingEngine.compute(samples: drift(0, days: 60))!.lowerConfidence,
                      "a 60-day span is a shorter fit than the 90-day window and should say so")
    }

    /// Connecting a new data source changes S for a reason that has nothing to do with how someone lived.
    /// Only the newest run sharing the newest factor signature is comparable, so the jump is never fitted
    /// — the user waits for the run to refill instead of being told they aged.
    func testAChangedFactorSetIsNotReadAsAging() {
        // 70 days on three factors, then 20 on four, with a large jump in S at the boundary.
        let mixed = (0..<90).map { i in
            PaceOfAgingEngine.Sample(dayIndex: i,
                                     lnHazardSum: i < 70 ? 0.20 : 0.90,
                                     factorSignature: i < 70 ? "hrv,rhr,sleep" : signature)
        }
        XCTAssertEqual(PaceOfAgingEngine.usableSamples(mixed).count, 20)
        XCTAssertNil(PaceOfAgingEngine.compute(samples: mixed))
        XCTAssertEqual(PaceOfAgingEngine.daysUntilReady(mixed), 40)
    }

    /// Samples older than the trend window are dropped even when the signature matches, and the run is
    /// broken by the window edge rather than quietly fitting a year of history.
    func testOnlyTheTrendWindowIsFitted() {
        var old = drift(0, days: 60)
        old += [PaceOfAgingEngine.Sample(dayIndex: 400, lnHazardSum: 0.20, factorSignature: signature)]
        // The newest sample is day 400; everything else is >90 days older, so nothing else is comparable.
        XCTAssertEqual(PaceOfAgingEngine.usableSamples(old).count, 1)
        XCTAssertNil(PaceOfAgingEngine.compute(samples: old))
    }

    /// Unordered input must not change the fit — the engine sorts before it windows.
    func testOrderIndependent() {
        let forward = drift(0.4)
        let shuffled = Array(forward.reversed())
        XCTAssertEqual(PaceOfAgingEngine.compute(samples: forward)!.pace,
                       PaceOfAgingEngine.compute(samples: shuffled)!.pace, accuracy: 1e-12)
    }

    /// No time base → no slope, rather than a divide-by-zero dressed as a number.
    func testAllSamplesOnOneDayYieldsNil() {
        let stacked = (0..<70).map { _ in
            PaceOfAgingEngine.Sample(dayIndex: 10, lnHazardSum: 0.2, factorSignature: signature)
        }
        XCTAssertNil(PaceOfAgingEngine.compute(samples: stacked))
    }

    func testEmptyInput() {
        XCTAssertNil(PaceOfAgingEngine.compute(samples: []))
        XCTAssertTrue(PaceOfAgingEngine.usableSamples([]).isEmpty)
        XCTAssertEqual(PaceOfAgingEngine.daysUntilReady([]), PaceOfAgingEngine.minSamples)
    }
}

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

extension PaceOfAgingEngineTests {

    /// The window floor is a real constraint, not decoration: a 30-day window is meant to be a habit, and
    /// half of it is the least that can pass for one.
    func testWindowFloorIsHalfTheWindow() {
        XCTAssertEqual(PaceOfAgingEngine.minWindowDays, PaceOfAgingEngine.recentWindowDays / 2)
        XCTAssertLessThan(PaceOfAgingEngine.minWindowDays, PaceOfAgingEngine.recentWindowDays)
    }
}
