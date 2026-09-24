import XCTest
import WhoopProtocol
@testable import StrandAnalytics

/// The deep-latency guard: descent into N3 runs through N1 and N2, so `SleepStagerV2` holds deep back for
/// the first minutes after sleep onset, the same way it holds REM back for the first hour.
final class SleepStagerV2DeepLatencyTests: XCTestCase {

    func testGuardShape() {
        XCTAssertEqual(SleepStagerV2.deepLatencyGuard(0), 3.0)
        XCTAssertEqual(SleepStagerV2.deepLatencyGuard(10), 1.5, accuracy: 1e-12)
        XCTAssertEqual(SleepStagerV2.deepLatencyGuard(20), 0.0)
        XCTAssertEqual(SleepStagerV2.deepLatencyGuard(45), 0.0)
        XCTAssertEqual(SleepStagerV2.deepLatencyGuard(-90), 3.0, "a pre-onset epoch is never penalised past onset's")
    }

    func testConstantsArePinned() {
        XCTAssertEqual(SleepStagerV2.deepLatencyPenalty, 3.0)
        XCTAssertEqual(SleepStagerV2.deepLatencyMinutes, 20.0)
        XCTAssertEqual(SleepStagerV2.deepLatencyPenalty, SleepStagerV2.remLatencyPenalty,
                       "the deep guard takes the REM guard's magnitude")
    }

    /// The golden night's first phase is a flat 50 bpm, which the HR-flatness gate reads as deep from the
    /// first epoch. Staged inside a window opening at 3600 s, the night used to enter through a single
    /// 30 s light epoch and go straight to deep; it now descends through 10.5 min of light. Everything
    /// after the first deep run is unchanged. Pinned verbatim from a run of the recipe.
    func testDeepWaitsForTheDescentThroughLight() {
        let start = 1_749_517_200, phase = 90 * 60, dur = phase * 4
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
        let segs = SleepStagerV2.stageSession(start: start, end: start + dur, grav: grav, hr: hr, rr: rr,
                                              resp: [], sleepWindow: (from: start + 3600, to: start + 18_000))
        XCTAssertEqual(segs.map { "\($0.start - start)-\($0.end - start) \($0.stage)" }, [
            "0-3600 wake", "3600-4230 light", "4230-5070 deep", "5070-10800 light",
            "10800-16200 rem", "16200-21600 wake"])
    }
}
