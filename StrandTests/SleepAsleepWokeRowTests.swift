import XCTest
import StrandDesign
import WhoopStore
@testable import Strand

/// The Sleep tab's Asleep / Woke row states when the hypnogram under it first and last shows sleep, not
/// the session's in-bed bounds. On a banked 5/MG night the band latency trim scores the lying-awake lead-in
/// and tail as wake inside those bounds: a night whose first sleep epoch came 2 h 7 min after its in-bed start
/// used to print that start as "Asleep", above a hypnogram that was still awake.
///
/// Pure: builds `Night` values directly, no store and no view mounting.
final class SleepAsleepWokeRowTests: XCTestCase {

    private let start = 1_700_000_000

    private func night(realSegments: [SleepInterval]?, startTsAdjusted: Int? = nil) -> Night {
        Night(session: CachedSleepSession(startTs: start, endTs: start + 40_380, efficiency: nil,
                                          restingHr: nil, avgHrv: nil, stagesJSON: nil,
                                          userEdited: false, startTsAdjusted: startTsAdjusted),
              stages: Stages(awake: 158, light: 290, deep: 78, rem: 135),
              realSegments: realSegments)
    }

    /// 2 h 7 min awake lead-in, sleep through the night, 2 min awake tail.
    private let trimmedNight: [SleepInterval] = [
        SleepInterval(stage: .awake, start: 0, end: 7_620),
        SleepInterval(stage: .light, start: 7_620, end: 8_250),
        SleepInterval(stage: .deep, start: 8_250, end: 10_000),
        SleepInterval(stage: .awake, start: 10_000, end: 10_300),
        SleepInterval(stage: .rem, start: 10_300, end: 40_260),
        SleepInterval(stage: .awake, start: 40_260, end: 40_380),
    ]

    func testRowReadsTheHypnogramsFirstAndLastSleep() {
        let n = night(realSegments: trimmedNight)
        XCTAssertEqual(n.sleepOnsetTs, start + 7_620, "the first non-wake interval, past the awake lead-in")
        XCTAssertEqual(n.finalWakeTs, start + 40_260, "the end of the last non-wake interval, before the tail")
        XCTAssertEqual(n.onsetText, Night.clockString(start + 7_620))
        XCTAssertEqual(n.wakeText, Night.clockString(start + 40_260))
    }

    func testInteriorWakeDoesNotMoveEitherEnd() {
        let n = night(realSegments: trimmedNight)
        XCTAssertNotEqual(n.finalWakeTs, start + 10_000, "an interior awake interval is not the final wake")
    }

    func testIntervalsAreMeasuredFromTheEffectiveStart() {
        // A hand-corrected bedtime moves the origin the intervals are laid from (`mergeDay` shifts them).
        let n = night(realSegments: trimmedNight, startTsAdjusted: start + 600)
        XCTAssertEqual(n.sleepOnsetTs, start + 600 + 7_620)
    }

    func testNightWithoutARealTimelineKeepsItsBounds() {
        let n = night(realSegments: nil)
        XCTAssertEqual(n.sleepOnsetTs, start)
        XCTAssertEqual(n.finalWakeTs, start + 40_380)
    }

    func testAllAwakeTimelineKeepsItsBounds() {
        let n = night(realSegments: [SleepInterval(stage: .awake, start: 0, end: 20_000),
                                     SleepInterval(stage: .awake, start: 20_000, end: 40_380)])
        XCTAssertEqual(n.sleepOnsetTs, start)
        XCTAssertEqual(n.finalWakeTs, start + 40_380)
    }
}
