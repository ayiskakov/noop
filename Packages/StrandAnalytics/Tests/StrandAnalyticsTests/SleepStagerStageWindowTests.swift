import XCTest
import WhoopProtocol
@testable import StrandAnalytics

/// `SleepStager.stageWindow` is the one staging funnel. `detectSleep` stages every accepted night through
/// it, and the app re-stages an edited night, a manually added nap and the post-sync self-heal window
/// through it as well. The re-stage used to call the recipe alone, without the band's sleep window or the
/// latency trim, so an edit that kept a night's bounds, or moved "Got up" by a few minutes, staged the
/// lying-awake lead-in as sleep again and moved the Asleep time back to the in-bed start.
final class SleepStagerStageWindowTests: XCTestCase {

    /// A 3 h still overnight window at 01:00 UTC with sleep-band HR and a regular R-R stream, which
    /// `detectSleep` accepts whole (the night `SleepStagerV2Tests.testDetectSleepThreadsV2FlagIntoNormalNight`
    /// uses).
    private let start = 1_749_517_200
    private let dur = 3 * 60 * 60
    private var grav: [GravitySample] { (0..<dur).map { GravitySample(ts: start + $0, x: 0, y: 0, z: 1.0) } }
    private var hr: [HRSample] { (0..<dur).map { HRSample(ts: start + $0, bpm: 52 + ($0 / 60) % 3) } }
    private var rr: [RRInterval] {
        (0..<dur).map { RRInterval(ts: start + $0, rrMs: 1000 + Int(40.0 * sin(2.0 * Double.pi * Double($0) / 4.0))) }
    }

    /// The band reads still-awake for the first hour and asleep after it. Its onset is epoch 120 and the
    /// window keeps 10 epochs of grace before it, so nothing before `start + 3300` may be sleep.
    private var band: [(ts: Int, state: Int)] { (0..<dur).map { (ts: start + $0, state: $0 < 3600 ? 1 : 2) } }
    private var bandOnset: Int { start + 3300 }

    private func detected(_ stager: SleepStagerVersion) -> SleepSession? {
        let sessions = SleepStager.detectSleep(hr: hr, rr: rr, gravity: grav, bandSleepState: band, stager: stager)
        XCTAssertEqual(sessions.count, 1, "\(stager.label): the still night must be detected")
        return sessions.first
    }

    private func firstSleep(_ stages: [StageSegment]) -> Int? {
        stages.first { !SleepStageVocabulary.isWake($0.stage) }?.start
    }

    func testARestageOverTheDetectedBoundsReproducesTheDetectedNight() {
        for stager in SleepStagerVersion.allCases {
            guard let night = detected(stager) else { continue }
            let restaged = SleepStager.stageWindow(start: night.start, end: night.end, grav: grav, hr: hr, rr: rr,
                                                   resp: [], bandSleepState: band, stager: stager)
            XCTAssertEqual(restaged.stages, night.stages, "\(stager.label): a re-stage must match the detected night")
            XCTAssertGreaterThanOrEqual(firstSleep(night.stages) ?? .max, bandOnset,
                                        "\(stager.label): nothing before the band's window is sleep")
        }
    }

    /// What the re-stage used to do: the recipe alone sleeps through the band's lying-awake hour.
    func testTheRecipeAloneStagesTheLeadInAsSleep() {
        for stager in SleepStagerVersion.allCases {
            guard let night = detected(stager) else { continue }
            let alone = stager.stageSession(start: night.start, end: night.end, grav: grav, hr: hr, rr: rr, resp: [])
            XCTAssertLessThan(firstSleep(alone) ?? .max, bandOnset,
                              "\(stager.label): this fixture must exercise the lead-in the funnel removes")
        }
    }

    func testMovingGotUpKeepsTheBandsOnset() {
        for stager in SleepStagerVersion.allCases {
            guard let night = detected(stager) else { continue }
            let edited = SleepStager.stageWindow(start: night.start, end: night.end - 300, grav: grav, hr: hr,
                                                 rr: rr, resp: [], bandSleepState: band, stager: stager).stages
            XCTAssertEqual(firstSleep(edited), firstSleep(night.stages),
                           "\(stager.label): an earlier Got up must not move Asleep")
        }
    }

    /// Without a band (WHOOP 4.0, or a window the strap never banked) the funnel is the recipe alone.
    func testWithoutABandTheFunnelIsTheRecipe() {
        for stager in SleepStagerVersion.allCases {
            let staged = SleepStager.stageWindow(start: start, end: start + dur, grav: grav, hr: hr, rr: rr, resp: [],
                                                 bandSleepState: [], stager: stager)
            let alone = stager.stageSession(start: start, end: start + dur, grav: grav, hr: hr, rr: rr, resp: [])
            XCTAssertEqual(staged.stages, alone, stager.label)
            XCTAssertEqual(staged.trimmed, alone, stager.label)
        }
    }
}
