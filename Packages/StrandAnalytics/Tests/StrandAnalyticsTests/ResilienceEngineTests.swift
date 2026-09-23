import Foundation
import XCTest
@testable import StrandAnalytics

/// The pieces of `ResilienceEngine`, each against a case whose answer is known exactly. The recovery of
/// injected τ and the negative controls are in `ResilienceOracleTests`.
final class ResilienceEngineTests: XCTestCase {

    typealias E = ResilienceEngine

    private func estimate(_ series: [E.DayValue], file: StaticString = #filePath,
                          line: UInt = #line) throws -> E.Estimate {
        let result = try XCTUnwrap(E.analyze(series: series, signal: .steps), file: file, line: line)
        return try XCTUnwrap(result.estimate, file: file, line: line)
    }

    // MARK: - Degenerate structure

    func testAPureRampIsRemovedNotReadAsALongTau() throws {
        let ramp = (0..<180).map { E.DayValue(dayIndex: $0, value: exp(8 + 0.01 * Double($0))) }
        let e = try estimate(ramp)
        XCTAssertEqual(e.tau, E.tauFloor)
        XCTAssertEqual(e.tauHigh, E.tauCeiling)
    }

    func testAPureWeeklyPatternIsRemovedNotReadAsASevenDayTau() throws {
        let week = [0.6, 0.2, 0.1, 0.0, 0.1, -0.5, -0.7]
        let pure = (0..<180).map { E.DayValue(dayIndex: $0, value: exp(8.8 + week[$0 % 7])) }
        XCTAssertEqual(try estimate(pure).tau, E.tauFloor)
    }

    // MARK: - Pipeline pieces

    func testDestructureRemovesWeekdayMeansAndTrendExactly() {
        let days = Array(stride(from: 3, to: 200, by: 1)).filter { $0 % 5 != 0 }
        let week = [1.0, -2, 0.5, 3, -1, 0, 2]
        let values = days.map { week[E.weekday($0)] + 0.03 * Double($0) - 4 }
        for r in E.Pipeline(days: days).destructure(values) { XCTAssertEqual(r, 0, accuracy: 1e-9) }
    }

    func testAutocorrelationOfAnAlternatingSeries() {
        let days = Array(0..<100)
        let values = days.map { $0 % 2 == 0 ? 1.0 : -1.0 }
        let pipeline = E.Pipeline(days: days)
        let (acf, _) = pipeline.autocorrelation(values)
        XCTAssertEqual(acf[0], -1, accuracy: 1e-12)
        XCTAssertEqual(acf[1], 1, accuracy: 1e-12)
        XCTAssertEqual(pipeline.pairs[0], 99)
        XCTAssertEqual(pipeline.pairs[27], 72)
        // A gap removes exactly the pairs that straddle it.
        XCTAssertEqual(E.Pipeline(days: days.filter { $0 != 50 }).pairs[0], 97)
    }

    func testFitRecoversAnExactExponential() {
        for (trueTau, trueA) in [(3.0, 0.4), (12, 0.6), (40, 0.9)] {
            let acf = (1...E.maxLag).map { trueA * exp(-Double($0) / trueTau) }
            let (tau, amplitude) = E.fit(acf: acf, pairs: [Int](repeating: 100, count: E.maxLag))
            XCTAssertEqual(tau, trueTau, accuracy: trueTau * 0.01)
            XCTAssertEqual(amplitude, trueA, accuracy: 0.01)
        }
    }

    // MARK: - Readiness and missing days

    func testCollectingUntilNinetyObservedDays() throws {
        let series = (0..<60).map { E.DayValue(dayIndex: $0, value: 8000) }
        let r = try XCTUnwrap(E.analyze(series: series, signal: .steps))
        XCTAssertNil(r.estimate)
        XCTAssertEqual(r.observedDays, 60)
        XCTAssertEqual(r.daysUntilReady, 30)
        XCTAssertNil(E.analyze(series: [], signal: .steps))
    }

    func testZeroAndUnwornDaysAreMissingNotZero() {
        let series = [E.DayValue(dayIndex: 1, value: 0), E.DayValue(dayIndex: 2, value: 40),
                      E.DayValue(dayIndex: 3, value: 9000), E.DayValue(dayIndex: 4, value: .nan)]
        XCTAssertEqual(E.observed(series, signal: .steps, endDay: 4).map(\.dayIndex), [3])
        XCTAssertEqual(E.observed([E.DayValue(dayIndex: 4, value: 0)], signal: .hrv, endDay: 4), [])
        XCTAssertEqual(E.observed([E.DayValue(dayIndex: 4, value: 55)], signal: .restingHR, endDay: 4),
                       [E.DayValue(dayIndex: 4, value: 55)])
    }

    func testTheWindowIsTheTrailingOneHundredEightyDays() {
        let series = (0..<400).map { E.DayValue(dayIndex: $0, value: 60) }
        let window = E.observed(series, signal: .restingHR, endDay: 300)
        XCTAssertEqual(window.first?.dayIndex, 121)
        XCTAssertEqual(window.last?.dayIndex, 300)
    }

    func testSameHistorySameAnswer() throws {
        var rng = E.SplitMix64(seed: 11)
        var y = 0.0
        let series = (0..<180).map { d -> E.DayValue in
            y = 0.9 * y + 0.44 * rng.nextGaussian()
            return E.DayValue(dayIndex: d, value: 55 + 3 * y)
        }
        let first = try XCTUnwrap(E.analyze(series: series, signal: .restingHR, replicates: 20))
        XCTAssertNotNil(first.estimate)
        XCTAssertEqual(first, E.analyze(series: series, signal: .restingHR, replicates: 20))
    }

    func testSplitMix64IsTheReferenceSequence() {
        // SplitMix64's published first outputs for seed 0 (Vigna): the bootstrap is portable only if
        // this generator is bit-exact everywhere.
        var rng = E.SplitMix64(seed: 0)
        XCTAssertEqual(rng.next(), 0xE220_A839_7B1D_CDAF)
        XCTAssertEqual(rng.next(), 0x6E78_9E6A_A1B9_65F4)
        XCTAssertEqual(rng.next(), 0x06C4_5D18_8009_454F)
    }

    func testOnlyStepsIsThePublishedSignal() {
        XCTAssertEqual(E.Signal.allCases.filter(\.isPublished), [.steps])
    }

    // MARK: - Knocks

    /// Knocks with half-lives of 1.5, 3 and 6 days injected into a quiet resting-HR series must each be
    /// found, with their half-lives recovered.
    func testKnocksRecoverSeveralInjectedHalfLives() {
        var rng = E.SplitMix64(seed: 42)
        let injected: [(day: Int, height: Double, halfLife: Double)] = [(30, 12, 1.5), (80, 10, 3), (130, 9, 6)]
        let series = (0..<180).map { d -> E.DayValue in
            var v = 55 + 1.0 * rng.nextGaussian()
            for k in injected where d >= k.day {
                v += k.height * exp(-Double(d - k.day) * log(2) / k.halfLife)
            }
            return E.DayValue(dayIndex: d, value: v)
        }
        let knocks = E.knocks(series: series, signal: .restingHR)
        for k in injected {
            let found = knocks.first { abs($0.peakDay - k.day) <= 1 }
            XCTAssertNotNil(found, "knock at day \(k.day)")
            guard let found else { continue }
            XCTAssertGreaterThan(found.peakDeviation, 0)
            let h = try? XCTUnwrap(found.halfLifeDays)
            XCTAssertEqual(h ?? 0, k.halfLife, accuracy: k.halfLife * 0.35, "day \(k.day)")
            XCTAssertNotNil(found.daysToBaseline)
            XCTAssertEqual(found.path.first?.dayIndex, 0)
            XCTAssertEqual(found.path.first?.value, abs(found.peakDeviation))
        }
        // The half-lives come back in the order they went in.
        let recovered = injected.compactMap { k in
            knocks.first { abs($0.peakDay - k.day) <= 1 }?.halfLifeDays
        }
        XCTAssertEqual(recovered, recovered.sorted())
    }

    func testADropIsAKnockWithANegativePeak() {
        var rng = E.SplitMix64(seed: 7)
        let series = (0..<120).map { d -> E.DayValue in
            let dip = d >= 60 ? -1.5 * exp(-Double(d - 60) / 2) : 0
            return E.DayValue(dayIndex: d, value: exp(9 + 0.1 * rng.nextGaussian() + dip))
        }
        let knock = E.knocks(series: series, signal: .steps).first { abs($0.peakDay - 60) <= 1 }
        XCTAssertNotNil(knock)
        XCTAssertLessThan(knock?.peakDeviation ?? 0, 0)
        XCTAssertGreaterThan(knock?.path.first?.value ?? 0, 0)
    }

    func testAKnockStillUnderwayHasNoReturnYet() {
        var rng = E.SplitMix64(seed: 5)
        let series = (0..<60).map { d -> E.DayValue in
            E.DayValue(dayIndex: d, value: d >= 58 ? 75 : 55 + rng.nextGaussian())
        }
        let last = E.knocks(series: series, signal: .restingHR).last
        XCTAssertEqual(last?.startDay, 58)
        XCTAssertNil(last?.daysToBaseline)
        XCTAssertNil(last?.halfLifeDays)
    }

    /// A two-day blip followed, two weeks on, by a second excursion: the return is observed, but no
    /// single decay describes the path, so no half-life is printed beside it.
    func testAPathNoDecayDescribesGetsNoHalfLife() throws {
        var rng = E.SplitMix64(seed: 13)
        let series = (0..<120).map { d -> E.DayValue in
            var v = 55 + rng.nextGaussian()
            if d == 60 { v += 5 }
            if d == 61 { v += 2.5 }
            if (74...80).contains(d) { v += 4 }
            return E.DayValue(dayIndex: d, value: v)
        }
        let knock = try XCTUnwrap(E.knocks(series: series, signal: .restingHR).first { $0.startDay == 60 })
        XCTAssertNotNil(knock.daysToBaseline)
        XCTAssertNil(knock.halfLifeDays)
        XCTAssertNil(knock.fittedReturn(atDay: 1))
    }

    func testALoneOutlierDayIsNotAKnock() {
        var rng = E.SplitMix64(seed: 9)
        let series = (0..<90).map { d -> E.DayValue in
            E.DayValue(dayIndex: d, value: d == 60 ? 75 : 55 + rng.nextGaussian())
        }
        XCTAssertFalse(E.knocks(series: series, signal: .restingHR).contains { $0.startDay == 60 })
    }
}
