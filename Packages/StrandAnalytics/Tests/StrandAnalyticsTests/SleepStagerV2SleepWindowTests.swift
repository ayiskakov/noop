import XCTest
import WhoopProtocol
@testable import StrandAnalytics

/// The band's sleep window as a constraint on `SleepStagerV2`'s lattice, rather than a relabelling applied
/// after staging. Pass 1 of the recipe reads sleep onset from its own hypnogram, and the REM-latency guard
/// runs from that onset, so the window has to be inside the lattice for the guard to start where sleep does.
final class SleepStagerV2SleepWindowTests: XCTestCase {

    /// 1 Hz band samples, one state per 30 s epoch starting at `start`.
    private func band(start: Int, _ perEpoch: [Int]) -> [(ts: Int, state: Int)] {
        perEpoch.enumerated().flatMap { i, s in (0..<30).map { (ts: start + i * 30 + $0, state: s) } }
    }

    /// 120 epochs: still(1) × 40, asleep(2) × 60, up(3) × 20.
    private func bandStillAsleepUp() -> [Int] {
        [Int](repeating: 1, count: 40) + [Int](repeating: 2, count: 60) + [Int](repeating: 3, count: 20)
    }

    // MARK: - bandSleepWindow

    func testBandSleepWindowIsTheSpanTheTrimKeeps() {
        // Onset epoch 40 − 10 grace → 30 (900 s); final epoch 99 + 10 grace → 109, which ends at 3300 s.
        let w = SleepStager.bandSleepWindow(start: 0, end: 3600,
                                            bandSleepState: band(start: 0, bandStillAsleepUp()), enabled: true)
        XCTAssertEqual(w?.from, 900)
        XCTAssertEqual(w?.to, 3300)

        // A session start off the 30 s wall-clock grid keeps the window on the session's own grid.
        let start = 1_749_517_215
        let shifted = SleepStager.bandSleepWindow(start: start, end: start + 3600,
                                                  bandSleepState: band(start: start, bandStillAsleepUp()),
                                                  enabled: true)
        XCTAssertEqual(shifted?.from, start + 900)
        XCTAssertEqual(shifted?.to, start + 3300)
    }

    func testBandSleepWindowRunsToTheSessionEndWhenTheBandSleepsThrough() {
        let w = SleepStager.bandSleepWindow(start: 0, end: 3590,
                                            bandSleepState: band(start: 0, [Int](repeating: 2, count: 120)),
                                            enabled: true)
        XCTAssertEqual(w?.from, 0)
        XCTAssertEqual(w?.to, 3590, "the last grid epoch is partial, so the window is clamped to the end")
    }

    func testBandSleepWindowIsNilWhereverTheTrimIsANoOp() {
        XCTAssertNil(SleepStager.bandSleepWindow(start: 0, end: 3600, bandSleepState: [], enabled: true))
        let sparse = band(start: 0, bandStillAsleepUp()).filter { $0.ts % 60 == 0 }
        XCTAssertNil(SleepStager.bandSleepWindow(start: 0, end: 3600, bandSleepState: sparse, enabled: true))
        XCTAssertNil(SleepStager.bandSleepWindow(start: 0, end: 3600,
                                                 bandSleepState: band(start: 0, [Int](repeating: 1, count: 120)),
                                                 enabled: true))
        XCTAssertNil(SleepStager.bandSleepWindow(start: 0, end: 3600,
                                                 bandSleepState: band(start: 0, bandStillAsleepUp()),
                                                 enabled: false))
    }

    // MARK: - epoch ↔ window grid

    func testEachEpochIsJudgedByTheSessionGridInstantItContains() {
        // Session grid starts at 1000 (10 s past a wall-clock boundary); window = grid epochs 5 ..< 20.
        let w = (from: 1_150, to: 1_600), end = 2_200
        XCTAssertFalse(SleepStagerV2.epochInSleepWindow(1_110, w, end: end), "[1110, 1140) holds 1120, before the window")
        XCTAssertTrue(SleepStagerV2.epochInSleepWindow(1_140, w, end: end), "[1140, 1170) holds 1150, the window's first")
        XCTAssertTrue(SleepStagerV2.epochInSleepWindow(1_560, w, end: end), "[1560, 1590) holds 1570, the window's last")
        XCTAssertFalse(SleepStagerV2.epochInSleepWindow(1_590, w, end: end), "[1590, 1620) holds 1600, past the end")
    }

    /// A session that starts off the wall-clock grid ends on a recipe epoch cut short at `end`. When that
    /// epoch holds no session-grid instant before `end`, it lies inside the session's last grid epoch and is
    /// judged by it. Judged by the instant past `end`, a band that slept through the end still closed the
    /// night on a few seconds of wake.
    func testThePartialLastEpochIsJudgedByTheSessionsLastGridEpoch() {
        // Session grid 15 s past the wall clock; 120 grid epochs, the last one [end - 20, end).
        let start = 1_699_999_995, end = start + 3_590
        let lastRecipeEpoch = end - 5   // [end - 5, end): the next grid instant is end + 10
        let band = (0..<(end - start)).map { (ts: start + $0, state: 2) }
        guard let w = SleepStager.bandSleepWindow(start: start, end: end, bandSleepState: band, enabled: true) else {
            return XCTFail("the band sleeps throughout")
        }
        XCTAssertEqual(w.to, end)
        XCTAssertTrue(SleepStagerV2.epochInSleepWindow(lastRecipeEpoch, w, end: end))
        XCTAssertFalse(SleepStagerV2.epochInSleepWindow(lastRecipeEpoch, (from: start, to: end - 20), end: end),
                       "a window that closes before the last grid epoch still excludes it")

        let grav = (start..<end).map { GravitySample(ts: $0, x: 0, y: 0, z: 1.0) }
        let hr = (start..<end).map { HRSample(ts: $0, bpm: 52 + (($0 - start) / 60) % 3) }
        for stager in [SleepStagerVersion.v2, .v3] {
            let stages = SleepStager.stageWindow(start: start, end: end, grav: grav, hr: hr, rr: [], resp: [],
                                                 bandSleepState: band, stager: stager).stages
            XCTAssertEqual(stages.last?.end, end)
            XCTAssertNotEqual(stages.last?.stage, "wake", "\(stager.label): the band slept through the end")
        }
    }

    // MARK: - staging inside the window

    /// The four-phase night of `SleepStagerV2Tests.testFrozenGoldenHypnogram`: flat 50 bpm, a gently
    /// varying 54–57, a stepped 56–59, then a restless 66–71 with wrist movement. 6 h at 1 Hz.
    private let start = 1_749_517_200
    private let dur = 4 * 90 * 60
    private func goldenNight() -> (grav: [GravitySample], hr: [HRSample], rr: [RRInterval]) {
        let phase = 90 * 60
        var grav: [GravitySample] = [], hr: [HRSample] = [], rr: [RRInterval] = []
        for i in 0..<dur {
            let ts = start + i, ph = i / phase
            let restless = ph == 3 && (i % 20) < 6
            grav.append(restless ? GravitySample(ts: ts, x: 0.2, y: 0.15, z: 0.96)
                                  : GravitySample(ts: ts, x: 0, y: 0, z: 1.0))
            let bpm: Int
            switch ph {
            case 0: bpm = 50
            case 1: bpm = 54 + [0, 1, 2, 3, 2, 1][(i / 20) % 6]
            case 2: bpm = 56 + ((i / 60) % 4)
            default: bpm = 66 + ((i / 30) % 6)
            }
            hr.append(HRSample(ts: ts, bpm: bpm))
            let amp = [12, 60, 30, 20][ph]
            rr.append(RRInterval(ts: ts, rrMs: (60_000 / bpm) + [0, amp, 0, -amp][i % 4]))
        }
        return (grav, hr, rr)
    }

    private func stage(_ n: (grav: [GravitySample], hr: [HRSample], rr: [RRInterval]),
                       window: (from: Int, to: Int)?) -> [StageSegment] {
        SleepStagerV2.stageSession(start: start, end: start + dur, grav: n.grav, hr: n.hr, rr: n.rr, resp: [],
                                   sleepWindow: window)
    }

    private func relative(_ segs: [StageSegment]) -> [String] {
        segs.map { "\($0.start - start)-\($0.end - start) \($0.stage)" }
    }

    /// Unconstrained, REM opens at 10 800 s, the moment the stepped phase begins. That is 30 min after a
    /// window opening at 9000 s, well inside the REM-latency guard, but the guard ran from the recipe's own
    /// onset at the session start and was long spent. Inside the lattice, onset is where the window opens
    /// and REM waits until 59.5 min after it. Pinned verbatim from a run of the recipe.
    func testRemLatencyGuardRunsFromTheWindowsOnset() {
        let night = goldenNight()
        XCTAssertEqual(relative(stage(night, window: nil)), [
            "0-480 light", "480-5070 deep", "5070-5310 light", "5310-5550 rem", "5550-10800 light",
            "10800-16200 rem", "16200-21600 wake"])
        XCTAssertEqual(relative(stage(night, window: (from: start + 9000, to: start + 18_000))), [
            "0-9000 wake", "9000-12570 light", "12570-16200 rem", "16200-21600 wake"])
        XCTAssertEqual(relative(stage(night, window: (from: start + 10_800, to: start + 18_000))), [
            "0-10800 wake", "10800-14250 light", "14250-16200 rem", "16200-21600 wake"])
    }

    func testEverythingOutsideTheWindowIsWakeAndSleepEntersThroughLight() {
        let night = goldenNight()
        for from in [3600, 5400, 9000, 10_800] {
            let w = (from: start + from, to: start + 18_000)
            let segs = stage(night, window: w)
            for s in segs where s.start < w.from || s.end > w.to {
                XCTAssertEqual(s.stage, "wake", "window from \(from): \(s) lies outside the window")
            }
            let firstSleep = segs.first { $0.stage != "wake" }
            XCTAssertEqual(firstSleep?.stage, "light", "window from \(from): the awake row forbids wake → deep/REM")
            XCTAssertEqual(firstSleep?.start, w.from)
        }
    }

    func testTheTrimFindsNothingLeftToRelabel() {
        let night = goldenNight()
        // A band that sleeps from epoch 130 through 569 gives the window [start + 3600, start + 17_400).
        let states = [Int](repeating: 1, count: 130) + [Int](repeating: 2, count: 440)
            + [Int](repeating: 3, count: 150)
        let b = band(start: start, states)
        guard let w = SleepStager.bandSleepWindow(start: start, end: start + dur, bandSleepState: b,
                                                  enabled: true) else { return XCTFail("no window") }
        XCTAssertEqual(w.from, start + 3600)
        XCTAssertEqual(w.to, start + 17_400)
        let constrained = stage(night, window: w)
        XCTAssertEqual(SleepStager.applyBandStateLatencyTrim(constrained, start: start, end: start + dur,
                                                             bandSleepState: b, enabled: true), constrained)
    }

    func testTheWindowIsPartOfTheCacheKey() {
        let night = goldenNight()
        let before = stage(night, window: nil)
        let constrained = stage(night, window: (from: start + 9000, to: start + 18_000))
        XCTAssertNotEqual(constrained, before)
        XCTAssertEqual(stage(night, window: nil), before, "a constrained result must never be served unconstrained")
    }
}
