import XCTest
import WhoopProtocol
@testable import StrandAnalytics

/// #103/#112 — the nightly `@82` candidate STATISTICS: mean, range and below-threshold runs.
///
/// `Spo2CandidateNightlyTests` beside this file pins the mean's gate. This file pins everything the mean
/// did not carry, because the night's minimum and its dips now reach a screen and a stored series — and
/// per AGENTS.md a helper whose output feeds stored rows is verified by ORACLE, not by eye. `testOracle`
/// below is that oracle: its expected literal is the real helper's own stdout over a spread of cases
/// (including the whole legal byte space), captured once and pinned verbatim. The named tests after it
/// say what each line is FOR, so a diff explains itself instead of only failing.
final class Spo2CandidateNightStatsTests: XCTestCase {

    private func sess(_ s: Int, _ d: Int) -> SleepSession {
        SleepSession(start: s, end: s + d, efficiency: 0.9, stages: [], restingHR: 50, avgHRV: 60)
    }
    private func aux(_ ts: Int, _ v: Int?) -> V18AuxSample { V18AuxSample(ts: ts, auxByte82: v) }

    /// One case's whole result as a single line — the format the oracle was captured in.
    private func line(_ name: String, _ sessions: [SleepSession], _ samples: [V18AuxSample]) -> String {
        guard let n = AnalyticsEngine.nightlySpo2CandidateNight(sessions, aux: samples) else {
            return "\(name) -> nil"
        }
        let ev = n.events.map { "\($0.start)-\($0.end)/n\($0.nadir)/s\($0.samples)/sp\($0.spanSeconds)" }
            .joined(separator: ",")
        return "\(name) -> mean=\(String(format: "%.6f", n.mean)) rounded=\(n.meanRounded) "
            + "min=\(n.minimum) max=\(n.maximum) samples=\(n.samples) thr=\(n.threshold) "
            + "below=\(n.samplesBelowThreshold) secs=\(n.secondsBelowThreshold) "
            + "nadir=\(n.nadir.map(String.init) ?? "-") events=[\(ev)]"
    }

    func testOracle() {
        var out: [String] = []
        out.append(line("flat-96", [sess(1000, 600)], (0..<10).map { aux(1000 + $0, 96) }))
        out.append(line("all-bytes", [sess(0, 300)], (0..<256).map { aux($0, $0) }))
        out.append(line("one-dip-77", [sess(1000, 600)],
                        [aux(1000, 96), aux(1001, 95), aux(1002, 77), aux(1003, 95)]))
        out.append(line("run-of-5", [sess(1000, 600)],
                        [aux(1000, 96)] + (1...5).map { aux(1000 + $0, 88) } + [aux(1006, 97)]))
        out.append(line("gap-split", [sess(1000, 6000)],
                        [aux(1000, 85), aux(1001, 86), aux(2000, 84), aux(2001, 83)]))
        out.append(line("recovery-split", [sess(1000, 600)],
                        [aux(1000, 85), aux(1001, 95), aux(1002, 86)]))
        out.append(line("run-of-5-shuffled", [sess(1000, 600)],
                        [aux(1003, 88), aux(1006, 97), aux(1000, 96), aux(1005, 88),
                         aux(1001, 88), aux(1004, 88), aux(1002, 88)]))
        out.append(line("out-of-band-only", [sess(1000, 600)],
                        [aux(1000, 0), aux(1001, 8), aux(1002, 0x80), aux(1003, 0xA0), aux(1004, nil)]))
        out.append(line("two-sessions", [sess(1000, 100), sess(5000, 100)],
                        [aux(1050, 92), aux(3000, 70), aux(5050, 88)]))
        out.append(line("edges", [sess(1000, 100)],
                        [aux(999, 80), aux(1000, 91), aux(1100, 89), aux(1101, 70)]))
        out.append(line("round-half-up", [sess(1000, 600)], [aux(1000, 96), aux(1001, 97)]))
        out.append(line("all-below", [sess(1000, 600)], (0..<4).map { aux(1000 + $0, 85 - $0) }))

        let expected = """
        flat-96 -> mean=96.000000 rounded=96 min=96 max=96 samples=10 thr=90 below=0 secs=0 nadir=- events=[]
        all-bytes -> mean=85.000000 rounded=85 min=70 max=100 samples=31 thr=90 below=20 secs=19 nadir=70 events=[70-89/n70/s20/sp19]
        one-dip-77 -> mean=90.750000 rounded=91 min=77 max=96 samples=4 thr=90 below=1 secs=0 nadir=77 events=[1002-1002/n77/s1/sp0]
        run-of-5 -> mean=90.428571 rounded=90 min=88 max=97 samples=7 thr=90 below=5 secs=4 nadir=88 events=[1001-1005/n88/s5/sp4]
        gap-split -> mean=84.500000 rounded=85 min=83 max=86 samples=4 thr=90 below=4 secs=2 nadir=83 events=[1000-1001/n85/s2/sp1,2000-2001/n83/s2/sp1]
        recovery-split -> mean=88.666667 rounded=89 min=85 max=95 samples=3 thr=90 below=2 secs=0 nadir=85 events=[1000-1000/n85/s1/sp0,1002-1002/n86/s1/sp0]
        run-of-5-shuffled -> mean=90.428571 rounded=90 min=88 max=97 samples=7 thr=90 below=5 secs=4 nadir=88 events=[1001-1005/n88/s5/sp4]
        out-of-band-only -> nil
        two-sessions -> mean=90.000000 rounded=90 min=88 max=92 samples=2 thr=90 below=1 secs=0 nadir=88 events=[5050-5050/n88/s1/sp0]
        edges -> mean=90.000000 rounded=90 min=89 max=91 samples=2 thr=90 below=1 secs=0 nadir=89 events=[1100-1100/n89/s1/sp0]
        round-half-up -> mean=96.500000 rounded=97 min=96 max=97 samples=2 thr=90 below=0 secs=0 nadir=- events=[]
        all-below -> mean=83.500000 rounded=84 min=82 max=85 samples=4 thr=90 below=4 secs=3 nadir=82 events=[1000-1003/n82/s4/sp3]
        """
        XCTAssertEqual(out.joined(separator: "\n"), expected)
    }

    // MARK: - What each oracle line is for

    /// The whole legal byte space in one pass: exactly the 31 values in 70...100 may survive, everything
    /// else — 0, the sub-70 diagnostic codes, every bit-7 sentinel — is refused. This is the single most
    /// damaging thing the helper could get wrong, because an average that swallowed a 0x80 would still
    /// look like a percentage.
    func testOnlyTheThirtyOneInBandBytesAreCounted() {
        let n = AnalyticsEngine.nightlySpo2CandidateNight([sess(0, 300)], aux: (0..<256).map { aux($0, $0) })
        XCTAssertEqual(n?.samples, 31)
        XCTAssertEqual(n?.minimum, 70)
        XCTAssertEqual(n?.maximum, 100)
    }

    /// The mean is stored UNROUNDED. The shipped series rounded it to an Int, so four nights that actually
    /// climbed 95.36 → 95.66 → 96.00 → 96.61 landed as 95/96/96/97 and the climb inside a percent was
    /// invisible. `meanRounded` still reproduces the old value for display.
    func testMeanKeepsSubPercentPrecisionAndRoundsOnlyForDisplay() {
        let n = AnalyticsEngine.nightlySpo2CandidateNight(
            [sess(1000, 600)], aux: [aux(1000, 96), aux(1001, 97), aux(1002, 97)])
        XCTAssertEqual(n!.mean, 96.66666666666667, accuracy: 1e-12)
        XCTAssertEqual(n?.meanRounded, 97)
    }

    /// The mean this replaces must not move. Same gate, same inclusive bounds, same rounding — the one
    /// resolver now answers both, so the pair cannot drift from the stats printed beside it.
    func testLegacyMeanDelegatesWithoutChangingItsAnswer() {
        let sessions = [sess(1000, 600)]
        let samples = [aux(1000, 96), aux(1001, 95), aux(1002, 77), aux(1003, 95)]
        let legacy = AnalyticsEngine.nightlySpo2CandidateMean(sessions, aux: samples)
        let night = AnalyticsEngine.nightlySpo2CandidateNight(sessions, aux: samples)
        XCTAssertEqual(legacy?.mean, night?.meanRounded)
        XCTAssertEqual(legacy?.samples, night?.samples)
        XCTAssertEqual(legacy?.mean, 91)
        XCTAssertNil(AnalyticsEngine.nightlySpo2CandidateMean([sess(1000, 600)], aux: [aux(1000, 8)]))
    }

    /// A dip is a run of ADJACENT below-threshold readings, so the result cannot depend on the order the
    /// rows arrived in — `v18AuxSamples` sorts, but that is a property of the query, not of this input.
    func testEventsAreResolvedInTimestampOrderNotArrivalOrder() {
        let ordered = [aux(1000, 96)] + (1...5).map { aux(1000 + $0, 88) } + [aux(1006, 97)]
        let shuffled = [aux(1003, 88), aux(1006, 97), aux(1000, 96), aux(1005, 88),
                        aux(1001, 88), aux(1004, 88), aux(1002, 88)]
        XCTAssertEqual(AnalyticsEngine.nightlySpo2CandidateNight([sess(1000, 600)], aux: ordered),
                       AnalyticsEngine.nightlySpo2CandidateNight([sess(1000, 600)], aux: shuffled))
    }

    /// Two dips separated by a stretch the strap did not report are TWO dips. Bridging them would print
    /// one event spanning a gap nothing was measured across.
    func testAGapWiderThanTheBudgetSplitsOneRunIntoTwo() {
        let n = AnalyticsEngine.nightlySpo2CandidateNight(
            [sess(1000, 6000)], aux: [aux(1000, 85), aux(1001, 86), aux(2000, 84), aux(2001, 83)])
        XCTAssertEqual(n?.events.count, 2)
        XCTAssertEqual(n?.events.first?.nadir, 85)
        XCTAssertEqual(n?.events.last?.nadir, 83)
        // Neither run's span may absorb the 999 s the strap said nothing across.
        XCTAssertEqual(n?.secondsBelowThreshold, 2)
    }

    /// A one-reading dip has a span of ZERO seconds, not one. The R18 stream is "roughly one packet per
    /// second", which is not a cadence guarantee, so `samples × 1 s` would state a duration nothing
    /// measured. The reading itself is still reported — via `samplesBelowThreshold` and `nadir`.
    func testASingleReadingDipReportsNoDurationButIsStillCounted() {
        let n = AnalyticsEngine.nightlySpo2CandidateNight(
            [sess(1000, 600)], aux: [aux(1000, 96), aux(1002, 77), aux(1003, 95)])
        XCTAssertEqual(n?.events.count, 1)
        XCTAssertEqual(n?.secondsBelowThreshold, 0)
        XCTAssertEqual(n?.samplesBelowThreshold, 1)
        XCTAssertEqual(n?.nadir, 77)
    }

    /// `nadir` is nil for a night that never dipped, so a surface can say "no dips" without inferring it
    /// from a `minimum` that legitimately sits above the threshold.
    func testNadirIsNilWithoutDipsAndMinimumStillReports() {
        let n = AnalyticsEngine.nightlySpo2CandidateNight(
            [sess(1000, 600)], aux: [aux(1000, 93), aux(1001, 98)])
        XCTAssertNil(n?.nadir)
        XCTAssertEqual(n?.minimum, 93)
        XCTAssertTrue(n!.events.isEmpty)
    }

    /// The threshold travels with the result so a screen names the number the dips were cut at instead of
    /// assuming the default.
    func testThresholdIsCarriedAndHonoured() {
        let samples = [aux(1000, 93), aux(1001, 96)]
        XCTAssertEqual(AnalyticsEngine.nightlySpo2CandidateNight([sess(1000, 600)], aux: samples)?.threshold, 90)
        let strict = AnalyticsEngine.nightlySpo2CandidateNight([sess(1000, 600)], aux: samples, threshold: 95)
        XCTAssertEqual(strict?.threshold, 95)
        XCTAssertEqual(strict?.samplesBelowThreshold, 1)
        XCTAssertEqual(strict?.nadir, 93)
    }

    /// Readings outside every in-bed span are daytime readings, and a night with none of its own has no
    /// answer at all rather than a zero.
    func testSessionBoundsAreInclusiveAndDaytimeIsExcluded() {
        let n = AnalyticsEngine.nightlySpo2CandidateNight(
            [sess(1000, 100)], aux: [aux(999, 80), aux(1000, 91), aux(1100, 89), aux(1101, 70)])
        XCTAssertEqual(n?.samples, 2)
        XCTAssertNil(AnalyticsEngine.nightlySpo2CandidateNight([sess(1000, 100)], aux: [aux(5000, 95)]))
        XCTAssertNil(AnalyticsEngine.nightlySpo2CandidateNight([], aux: [aux(1000, 95)]))
    }
}

/// #103 — the stored-series funnel. These pin the thing a card cannot be trusted to do for itself:
/// putting FIGURES FROM ONE NIGHT on one card. Each series is written by the same scoring pass, but they
/// are separate rows, and a surface resolving each key independently could pair last night's mean with an
/// older night's minimum the moment one row was missing.
final class Spo2CandidateSeriesTests: XCTestCase {

    func testLatestResolvesEveryFigureFromTheSameDay() {
        let n = Spo2CandidateSeries.latest(
            mean: ["2026-09-21": 95.66, "2026-09-22": 96.61],
            minimum: ["2026-09-21": 88, "2026-09-22": 92],
            dips: ["2026-09-21": 3, "2026-09-22": 0],
            dipSeconds: ["2026-09-21": 41, "2026-09-22": 0],
            samples: ["2026-09-21": 722, "2026-09-22": 570])
        XCTAssertEqual(n?.day, "2026-09-22")
        XCTAssertEqual(n?.meanRounded, 97)
        XCTAssertEqual(n?.minimum, 92)
        XCTAssertEqual(n?.dips, 0)
        XCTAssertEqual(n?.samples, 570)
        XCTAssertEqual(n?.dipped, false)
    }

    /// A companion series lagging a scoring pass behind must NOT be back-filled from an older night. The
    /// card would then print one night's mean beside another night's low and look entirely plausible.
    func testAStaleCompanionSeriesIsNotBorrowedFromAnEarlierNight() {
        let n = Spo2CandidateSeries.latest(
            mean: ["2026-09-21": 95.66, "2026-09-22": 96.61],
            minimum: ["2026-09-21": 88])
        XCTAssertEqual(n?.day, "2026-09-22")
        XCTAssertNil(n?.minimum, "88 belongs to the 21st and must not decorate the 22nd")
    }

    /// A night scored before these keys existed has a mean and nothing else. `dips == nil` is UNKNOWN, so
    /// `dipped` stays nil — a surface must not caption such a night "no dips" off a row never written.
    func testPreKeysNightKeepsItsMeanAndReportsUnknownRatherThanZero() {
        let n = Spo2CandidateSeries.latest(mean: ["2026-09-19": 95.36])
        XCTAssertEqual(n?.meanRounded, 95)
        XCTAssertNil(n?.dips)
        XCTAssertNil(n?.dipped)
        XCTAssertNil(n?.samples)
    }

    /// The mean decides which nights exist. A companion row without one is a half-written night.
    func testANightPresentOnlyInACompanionSeriesIsNotShown() {
        XCTAssertNil(Spo2CandidateSeries.latest(mean: [:], minimum: ["2026-09-22": 92]))
        let n = Spo2CandidateSeries.latest(mean: ["2026-09-20": 96.0],
                                           minimum: ["2026-09-30": 70])
        XCTAssertEqual(n?.day, "2026-09-20")
        XCTAssertNil(n?.minimum)
    }

    /// The mean keeps its precision through the funnel and rounds exactly as the resolver's own
    /// `meanRounded` does, so the card and the vital tile cannot show two different numbers for one night.
    func testMeanPrecisionSurvivesAndRoundsLikeTheResolver() {
        let n = Spo2CandidateSeries.latest(mean: ["2026-09-22": 96.61])
        XCTAssertEqual(n!.mean, 96.61, accuracy: 1e-12)
        XCTAssertEqual(n?.meanRounded, 97)
    }

    /// The keys are the contract between the scoring pass and every reader. Pinned verbatim: a rename is
    /// a silent data loss on both ends (the writer banks under a key nothing reads, the reader finds
    /// nothing and shows a night with no stats), and neither side fails to compile.
    func testStoredKeysArePinned() {
        XCTAssertEqual(Spo2CandidateSeries.meanKey, "spo2_candidate")
        XCTAssertEqual(Spo2CandidateSeries.minimumKey, "spo2_candidate_min")
        XCTAssertEqual(Spo2CandidateSeries.dipsKey, "spo2_candidate_dips")
        XCTAssertEqual(Spo2CandidateSeries.dipSecondsKey, "spo2_candidate_dip_seconds")
        XCTAssertEqual(Spo2CandidateSeries.samplesKey, "spo2_candidate_samples")
    }
}
