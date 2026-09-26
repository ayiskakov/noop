import XCTest
import WhoopProtocol
@testable import StrandAnalytics

/// #103/#112 — the nightly `@82` candidate STATISTICS: mean, range, dip windows and window counts.
///
/// `Spo2CandidateNightlyTests` beside this file pins the mean's gate. This file pins everything the mean
/// did not carry, because the night's minimum and its dips now reach a screen and a stored series — and
/// per AGENTS.md a helper whose output feeds stored rows is verified by ORACLE, not by eye. `testOracle`
/// below is that oracle: its expected literal is the real helper's own output over a spread of cases
/// (including the whole legal byte space and a night of real-shaped 30-second windows), captured once,
/// checked line for line against an independent Python implementation of the per-window rule (W03-003),
/// and pinned verbatim. The named tests after it say what each line is FOR, so a diff explains itself
/// instead of only failing.
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
            + "min=\(n.minimum) max=\(n.maximum) samples=\(n.samples) "
            + "windows=\(n.windows)/\(n.windowsAttempted) thr=\(n.threshold) "
            + "below=\(n.dipSamples) secs=\(n.dipSpanSeconds) "
            + "nadir=\(n.nadir.map(String.init) ?? "-") events=[\(ev)]"
    }

    /// A 30-second window starting at `start`, one value per second from `values` (cycled).
    private func window(_ start: Int, _ values: [Int?]) -> [V18AuxSample] {
        (0..<30).map { aux(start + $0, values[$0 % values.count]) }
    }

    func testOracle() {
        var out: [String] = []
        out.append(line("flat-96", [sess(1000, 600)], (0..<10).map { aux(1000 + $0, 96) }))
        out.append(line("all-bytes-contiguous", [sess(0, 300)], (0..<256).map { aux($0, $0) }))
        out.append(line("all-bytes-per-window", [sess(0, 256 * 1200)], (0..<256).map { aux($0 * 1200, $0) }))
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
        out.append(line("round-half-up", [sess(1000, 1800)], [aux(1000, 96), aux(2200, 97)]))
        out.append(line("all-below", [sess(1000, 600)], (0..<4).map { aux(1000 + $0, 85 - $0) }))
        // Real window shapes: a night of 30-second windows 1200 s apart.
        out.append(line("night-of-windows", [sess(0, 6 * 1200)],
                        window(0, [16, 32, 95, 96, 96, 95, 97]) + window(1200, [94, 95, 94])
                        + window(2400, [8, 40, 136, 168]) + window(3600, [96, 77, 96, 97, 95])
                        + window(4800, [89, 88, 89, 90, 88]) + window(6000, [nil, 93, 0, 94])))
        out.append(line("even-count-lower-median", [sess(1000, 600)], [aux(1000, 91), aux(1001, 89)]))
        out.append(line("gap-at-budget", [sess(1000, 600)], [aux(1000, 95), aux(1030, 85), aux(1061, 85)]))
        out.append(line("window-straddles-session-end", [sess(1000, 15)], window(1000, [88, 97])))

        let expected = """
        flat-96 -> mean=96.000000 rounded=96 min=96 max=96 samples=10 windows=1/1 thr=90 below=0 secs=0 nadir=- events=[]
        all-bytes-contiguous -> mean=85.000000 rounded=85 min=85 max=85 samples=31 windows=1/5 thr=90 below=31 secs=30 nadir=85 events=[70-100/n85/s31/sp30]
        all-bytes-per-window -> mean=85.000000 rounded=85 min=70 max=100 samples=31 windows=31/255 thr=90 below=20 secs=0 nadir=70 events=[84000-84000/n70/s1/sp0,85200-85200/n71/s1/sp0,86400-86400/n72/s1/sp0,87600-87600/n73/s1/sp0,88800-88800/n74/s1/sp0,90000-90000/n75/s1/sp0,91200-91200/n76/s1/sp0,92400-92400/n77/s1/sp0,93600-93600/n78/s1/sp0,94800-94800/n79/s1/sp0,96000-96000/n80/s1/sp0,97200-97200/n81/s1/sp0,98400-98400/n82/s1/sp0,99600-99600/n83/s1/sp0,100800-100800/n84/s1/sp0,102000-102000/n85/s1/sp0,103200-103200/n86/s1/sp0,104400-104400/n87/s1/sp0,105600-105600/n88/s1/sp0,106800-106800/n89/s1/sp0]
        one-dip-77 -> mean=95.000000 rounded=95 min=95 max=95 samples=4 windows=1/1 thr=90 below=0 secs=0 nadir=- events=[]
        run-of-5 -> mean=88.000000 rounded=88 min=88 max=88 samples=7 windows=1/1 thr=90 below=7 secs=6 nadir=88 events=[1000-1006/n88/s7/sp6]
        gap-split -> mean=84.000000 rounded=84 min=83 max=85 samples=4 windows=2/2 thr=90 below=4 secs=2 nadir=83 events=[1000-1001/n85/s2/sp1,2000-2001/n83/s2/sp1]
        recovery-split -> mean=86.000000 rounded=86 min=86 max=86 samples=3 windows=1/1 thr=90 below=3 secs=2 nadir=86 events=[1000-1002/n86/s3/sp2]
        run-of-5-shuffled -> mean=88.000000 rounded=88 min=88 max=88 samples=7 windows=1/1 thr=90 below=7 secs=6 nadir=88 events=[1000-1006/n88/s7/sp6]
        out-of-band-only -> nil
        two-sessions -> mean=90.000000 rounded=90 min=88 max=92 samples=2 windows=2/2 thr=90 below=1 secs=0 nadir=88 events=[5050-5050/n88/s1/sp0]
        edges -> mean=90.000000 rounded=90 min=89 max=91 samples=2 windows=2/2 thr=90 below=1 secs=0 nadir=89 events=[1100-1100/n89/s1/sp0]
        round-half-up -> mean=96.500000 rounded=97 min=96 max=97 samples=2 windows=2/2 thr=90 below=0 secs=0 nadir=- events=[]
        all-below -> mean=83.000000 rounded=83 min=83 max=83 samples=4 windows=1/1 thr=90 below=4 secs=3 nadir=83 events=[1000-1003/n83/s4/sp3]
        night-of-windows -> mean=93.600000 rounded=94 min=89 max=96 samples=125 windows=5/6 thr=90 below=30 secs=29 nadir=89 events=[4800-4829/n89/s30/sp29]
        even-count-lower-median -> mean=89.000000 rounded=89 min=89 max=89 samples=2 windows=1/1 thr=90 below=2 secs=1 nadir=89 events=[1000-1001/n89/s2/sp1]
        gap-at-budget -> mean=85.000000 rounded=85 min=85 max=85 samples=3 windows=2/2 thr=90 below=3 secs=30 nadir=85 events=[1000-1030/n85/s2/sp30,1061-1061/n85/s1/sp0]
        window-straddles-session-end -> mean=88.000000 rounded=88 min=88 max=88 samples=16 windows=1/1 thr=90 below=16 secs=15 nadir=88 events=[1000-1015/n88/s16/sp15]
        """
        XCTAssertEqual(out.joined(separator: "\n"), expected)
    }

    // MARK: - What each oracle line is for

    /// The whole legal byte space, one byte per window: exactly the 31 values in 70...100 may give a window
    /// a value, and everything else — the sub-70 diagnostic codes and every bit-7 sentinel — only marks a
    /// window as attempted. This is the single most damaging thing the helper could get wrong, because an
    /// average that swallowed a 0x80 would still look like a percentage. (0 is "not measuring" and opens
    /// no window at all.)
    func testOnlyTheThirtyOneInBandBytesGiveAWindowAValue() {
        let n = AnalyticsEngine.nightlySpo2CandidateNight(
            [sess(0, 256 * 1200)], aux: (0..<256).map { aux($0 * 1200, $0) })
        XCTAssertEqual(n?.samples, 31)
        XCTAssertEqual(n?.windows, 31)
        XCTAssertEqual(n?.windowsAttempted, 255)
        XCTAssertEqual(n?.minimum, 70)
        XCTAssertEqual(n?.maximum, 100)
    }

    /// The mean is stored UNROUNDED. The shipped series rounded it to an Int, so four nights that actually
    /// climbed within one percent landed as three whole numbers and the climb was invisible. `meanRounded`
    /// still reproduces the rounded value for display.
    func testMeanKeepsSubPercentPrecisionAndRoundsOnlyForDisplay() {
        let n = AnalyticsEngine.nightlySpo2CandidateNight(
            [sess(1000, 3000)], aux: [aux(1000, 96), aux(2200, 97), aux(3400, 97)])
        XCTAssertEqual(n!.mean, 96.66666666666667, accuracy: 1e-12)
        XCTAssertEqual(n?.meanRounded, 97)
    }

    /// The legacy mean is the resolver's own mean, rounded, so the pair cannot drift from the stats
    /// printed beside it. Since W03-003 that mean is per window: the one-second 77 inside this window no
    /// longer drags it from 95 to 91.
    func testLegacyMeanDelegatesToTheResolver() {
        let sessions = [sess(1000, 600)]
        let samples = [aux(1000, 96), aux(1001, 95), aux(1002, 77), aux(1003, 95)]
        let legacy = AnalyticsEngine.nightlySpo2CandidateMean(sessions, aux: samples)
        let night = AnalyticsEngine.nightlySpo2CandidateNight(sessions, aux: samples)
        XCTAssertEqual(legacy?.mean, night?.meanRounded)
        XCTAssertEqual(legacy?.samples, night?.samples)
        XCTAssertEqual(legacy?.mean, 95)
        XCTAssertNil(AnalyticsEngine.nightlySpo2CandidateMean([sess(1000, 600)], aux: [aux(1000, 8)]))
    }

    /// Windows are resolved by adjacency, so the result cannot depend on the order the rows arrived in —
    /// `v18AuxSamples` sorts, but that is a property of the query, not of this input.
    func testWindowsAreResolvedInTimestampOrderNotArrivalOrder() {
        let ordered = [aux(1000, 96)] + (1...5).map { aux(1000 + $0, 88) } + [aux(1006, 97)]
            + [aux(2200, 85), aux(2201, 86)]
        let shuffled = [aux(1003, 88), aux(2201, 86), aux(1006, 97), aux(1000, 96), aux(1005, 88),
                        aux(1001, 88), aux(2200, 85), aux(1004, 88), aux(1002, 88)]
        XCTAssertEqual(AnalyticsEngine.nightlySpo2CandidateNight([sess(1000, 1800)], aux: ordered),
                       AnalyticsEngine.nightlySpo2CandidateNight([sess(1000, 1800)], aux: shuffled))
    }

    /// Two measurements separated by a stretch the strap did not report are TWO windows. Bridging them
    /// would print one dip spanning a gap nothing was measured across.
    func testAGapWiderThanTheBudgetSplitsTwoWindows() {
        let n = AnalyticsEngine.nightlySpo2CandidateNight(
            [sess(1000, 6000)], aux: [aux(1000, 85), aux(1001, 86), aux(2000, 84), aux(2001, 83)])
        XCTAssertEqual(n?.windows, 2)
        XCTAssertEqual(n?.events.count, 2)
        XCTAssertEqual(n?.events.first?.nadir, 85)
        XCTAssertEqual(n?.events.last?.nadir, 83)
        // Neither window's span may absorb the 999 s the strap said nothing across.
        XCTAssertEqual(n?.dipSpanSeconds, 2)
    }

    /// The gap budget is inclusive: seconds exactly `spo2CandidateWindowGapSeconds` apart are one window,
    /// one second more makes two.
    func testTheWindowGapBudgetIsInclusive() {
        let gap = AnalyticsEngine.spo2CandidateWindowGapSeconds
        let joined = AnalyticsEngine.nightlySpo2CandidateNight(
            [sess(1000, 600)], aux: [aux(1000, 95), aux(1000 + gap, 95)])
        let split = AnalyticsEngine.nightlySpo2CandidateNight(
            [sess(1000, 600)], aux: [aux(1000, 95), aux(1001 + gap, 95)])
        XCTAssertEqual(joined?.windows, 1)
        XCTAssertEqual(split?.windows, 2)
    }

    /// A strap that reported the byte continuously must not collapse the night into one window with one
    /// median: the span cap cuts the stream into readings, so a real ten-minute stretch below the threshold
    /// still shows as dips and as the night's low.
    func testAContinuousStreamIsCutIntoReadingsSoALongDipSurvives() {
        let night = (0..<(8 * 3600)).map { aux($0, (3600..<4200).contains($0) ? 85 : 96) }
        let n = AnalyticsEngine.nightlySpo2CandidateNight([sess(0, 8 * 3600)], aux: night)
        XCTAssertEqual(n?.minimum, 85)
        XCTAssertEqual(n?.events.count, 10)
        XCTAssertEqual(n?.windows, 480)
    }

    /// A window stretched by a stepped or skipped timestamp stays ONE window: splitting off its last second
    /// would make that second a reading of its own, and a single blip a dip.
    func testAWindowStretchedByAClockStepStaysWhole() {
        let stretched = (0..<29).map { aux(1000 + $0, 96) } + [aux(1033, 77)]
        let n = AnalyticsEngine.nightlySpo2CandidateNight([sess(1000, 600)], aux: stretched)
        XCTAssertEqual(n?.windowsAttempted, 1)
        XCTAssertEqual(n?.events.count, 0)
        XCTAssertEqual(n?.minimum, 96)
    }

    /// Failure codes are the strap MEASURING and failing, so they hold a window together and a window of
    /// nothing but codes still counts as attempted. Zero is the strap not measuring at all.
    func testCodesHoldAWindowTogetherAndACodeOnlyWindowIsAttemptedNotValued() {
        let window1 = [aux(1000, 32), aux(1001, 95)] + (2..<20).map { aux(1000 + $0, 8) } + [aux(1020, 96)]
        let window2 = (0..<30).map { aux(2200 + $0, $0 % 2 == 0 ? 136 : 40) }
        let n = AnalyticsEngine.nightlySpo2CandidateNight([sess(1000, 1800)],
                                                          aux: window1 + window2 + [aux(3000, 0)])
        XCTAssertEqual(n?.windowsAttempted, 2)
        XCTAssertEqual(n?.windows, 1)
        XCTAssertEqual(n?.samples, 2)
        XCTAssertEqual(n?.minimum, 95, "the lower of the two middle readings: always a reported value")
    }

    /// A window whose only in-band second is below the threshold is a dip with a span of ZERO seconds, not
    /// one. The R18 stream is "roughly one packet per second", which is not a cadence guarantee, so
    /// `samples × 1 s` would state a duration nothing measured. The window itself is still reported — via
    /// `dipSamples` and `nadir`.
    func testASingleReadingDipWindowReportsNoDurationButIsStillCounted() {
        let n = AnalyticsEngine.nightlySpo2CandidateNight(
            [sess(1000, 1800)], aux: [aux(1000, 8), aux(1001, 88), aux(1002, 8), aux(2200, 96)])
        XCTAssertEqual(n?.events.count, 1)
        XCTAssertEqual(n?.dipSpanSeconds, 0)
        XCTAssertEqual(n?.dipSamples, 1)
        XCTAssertEqual(n?.nadir, 88)
    }

    /// A window that sits below the threshold for most of its seconds is a dip, whatever single seconds
    /// inside it read — the counterpart to the blip test below.
    func testAWindowMostlyBelowTheThresholdIsADip() {
        let window = (0..<30).map { aux(1000 + $0, $0 < 19 ? 88 + $0 % 2 : 91) }
        let n = AnalyticsEngine.nightlySpo2CandidateNight([sess(1000, 600)], aux: window)
        XCTAssertEqual(n?.events.count, 1)
        XCTAssertEqual(n?.nadir, 89)
        XCTAssertEqual(n?.dipSamples, 30)
        XCTAssertEqual(n?.dipSpanSeconds, 29)
    }

    /// `nadir` is nil for a night that never dipped, so a surface can say "no dips" without inferring it
    /// from a `minimum` that legitimately sits above the threshold.
    func testNadirIsNilWithoutDipsAndMinimumStillReports() {
        let n = AnalyticsEngine.nightlySpo2CandidateNight(
            [sess(1000, 1800)], aux: [aux(1000, 93), aux(2200, 98)])
        XCTAssertNil(n?.nadir)
        XCTAssertEqual(n?.minimum, 93)
        XCTAssertTrue(n!.events.isEmpty)
    }

    /// The threshold travels with the result so a screen names the number the dips were cut at instead of
    /// assuming the default.
    func testThresholdIsCarriedAndHonoured() {
        let samples = [aux(1000, 93), aux(2200, 96)]
        XCTAssertEqual(AnalyticsEngine.nightlySpo2CandidateNight([sess(1000, 1800)], aux: samples)?.threshold, 90)
        let strict = AnalyticsEngine.nightlySpo2CandidateNight([sess(1000, 1800)], aux: samples, threshold: 95)
        XCTAssertEqual(strict?.threshold, 95)
        XCTAssertEqual(strict?.dipSamples, 1)
        XCTAssertEqual(strict?.nadir, 93)
    }

    /// W03-003: byte 82 arrives in 30-second windows, and inside one the strap's rolling value moves a few
    /// points and can blip for a single second. A window that reads 95–96 with one second at 77 is not a
    /// night that dipped to 77.
    func testASingleSecondBlipInsideAWindowIsNotADip() {
        let window = (0..<30).map { aux(1000 + $0, $0 == 12 ? 77 : 95 + $0 % 2) }
        let n = AnalyticsEngine.nightlySpo2CandidateNight([sess(1000, 600)], aux: window)
        XCTAssertEqual(n?.events.count, 0)
        XCTAssertEqual(n?.minimum, 95)
        XCTAssertEqual(n?.windows, 1)
        XCTAssertEqual(n?.samples, 30)
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
        XCTAssertEqual(Spo2CandidateSeries.windowsKey, "spo2_candidate_windows")
        XCTAssertEqual(Spo2CandidateSeries.windowsAttemptedKey, "spo2_candidate_windows_attempted")
    }

    /// The window counts resolve from the same night as every other figure (W03-003).
    func testWindowCountsResolveFromTheSameNight() {
        let n = Spo2CandidateSeries.latest(
            mean: ["2026-09-21": 95.66, "2026-09-22": 96.61],
            windows: ["2026-09-21": 26, "2026-09-22": 20],
            windowsAttempted: ["2026-09-21": 26, "2026-09-22": 22])
        XCTAssertEqual(n?.windows, 20)
        XCTAssertEqual(n?.windowsAttempted, 22)
    }

    /// A night scored before the window keys shipped has no window count. Its minimum and dips were
    /// resolved per second, and the nil count is how a surface knows not to present them as per window.
    func testPreWindowKeysNightReportsNoWindowCount() {
        let n = Spo2CandidateSeries.latest(mean: ["2026-09-20": 96.0], minimum: ["2026-09-20": 77],
                                           dips: ["2026-09-20": 4], samples: ["2026-09-20": 639])
        XCTAssertEqual(n?.minimum, 77)
        XCTAssertNil(n?.windows)
        XCTAssertNil(n?.windowsAttempted)
    }
}
